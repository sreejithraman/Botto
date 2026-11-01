import Foundation

extension HermesBotService {
    public func replaceQueuedMessage(_ message: QueuedMessage, text: String, access: ConversationAccess,
                                     operationID: UUID) async throws -> MutationReceipt {
        try Task.checkCancellation()
        return try await Task { try await self.replaceQueued(message, text: text, access: access, operationID: operationID) }.value
    }

    private func replaceQueued(_ message: QueuedMessage, text: String, access: ConversationAccess,
                               operationID: UUID) async throws -> MutationReceipt {
        let context = try resolve(access), conversation = context.state.conversation
        try claimOperation(operationID)
        try validateQueuedMessage(message)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HermesServiceError.invalidResponse }
        guard !sending.contains(context.identity) else { throw HermesServiceError.staleConversation }
        let socket = try requireSelected(conversation)
        guard let configuration else { throw HermesServiceError.disconnected }
        let submission = operationID.uuidString
        try journal.record(submission, connection: configuration.id, profile: conversation.profileID, stored: conversation.storedID)
        let observation = state?.queueObservation
        state?.queuedReplacement = .init(submission: submission)
        sending.insert(context.identity)
        defer {
            sending.remove(context.identity)
            if exact(state?.queuedReplacement?.submission, submission) { state?.queuedReplacement = nil }
        }
        let reply: HermesJSON
        do {
            reply = try await socket.call("prompt.replace_queued", ["profile": .string(conversation.profileID),
                "session_id": .string(conversation.id), "admission_id": .string(message.id),
                "submission_id": .string(submission), "text": .string(text)], mutation: true, validate: {
                    try self.validate(access)
                    try self.validateQueuedMessage(message)
                })
        } catch {
            // The gateway retains the authority's refusal code, without its private body.
            // 4001 covers admission_started, unsupported_control and not_found (and other
            // definite replacement refusals). None authorizes another delivery path.
            if (error as? HermesServiceError) == .rejected(4001) { throw HermesServiceError.queuedMessageUnavailable }
            if (error as? HermesServiceError) == .uncertain, isSelected(context) { scheduleRefresh() }
            throw error
        }
        guard let admission = reply["admission_id"].nonempty, !exact(admission, message.id),
              exact(reply["ref"]["session_id"].text, conversation.id),
              exact(reply["ref"]["profile_id"].text, context.state.profileIdentity),
              ["queued", "started", "unknown", "terminal"].contains(reply["status"].text ?? "") else {
            throw HermesServiceError.uncertain
        }
        var durability = JournalDurability.saved
        do { try journal.acknowledge(submission, admission: admission) } catch { durability = .needsLocalRepair }
        guard reply["status"].text != "unknown" else { throw HermesServiceError.uncertain }
        if isSelected(context), exact(state?.subscription, context.state.subscription), exact(state?.epoch, context.state.epoch) {
            state?.conversation.queuedMessages.removeAll { exact($0.id, message.id) }
            if let oldSubmission = message.submissionID {
                let id = "submission:" + oldSubmission
                if state?.optimistic.contains(id) == true {
                    state?.conversation.messages.removeAll { exact($0.id, id) }
                    state?.optimistic.removeAll { exact($0, id) }
                }
            }
            if reply["status"].text == "queued" {
                state?.confirmQueuedReceipt(admission: admission, text: text, submission: submission, observation: observation)
            }
            let startedTurn = state?.queuedReplacement?.turn(admission)
            if ["queued", "started"].contains(reply["status"].text ?? ""),
               state?.queueObservation == observation || state?.conversation.queuedMessages.contains(where: { exact($0.id, admission) }) == true || startedTurn != nil {
                state?.addSubmittedText(text, submission: submission, beforeMessageID: startedTurn?.beforeMessageID)
            }
            emitConversation()
            if reply["status"].text == "terminal" { scheduleRefresh() }
        }
        onEvent?(.botsChanged)
        return receipt(operationID, context: context, admission: admission, journal: durability)
    }

    private func validateQueuedMessage(_ message: QueuedMessage) throws {
        guard adapter == .authority, message.canEdit, !message.isSteering,
              state?.conversation.queuedMessages.contains(where: {
                  $0.canEdit && !$0.isSteering && exact($0.id, message.id) && exact($0.text, message.text)
                      && exact($0.submissionID, message.submissionID)
              }) == true else { throw HermesServiceError.queuedMessageUnavailable }
    }

    public func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        try Task.checkCancellation()
        // The operation outlives the view task. Navigation cannot cancel an already sent mutation.
        return try await Task {
            switch delivery {
            case .queue: return try await self.submit(text: text, attachments: attachments, access: access, operationID: operationID)
            case .steer:
                guard attachments.isEmpty else { throw HermesServiceError.steeringAttachments }
                return try await self.steer(text: text, access: access, operationID: operationID)
            }
        }.value
    }

    func submit(text: String, attachments: [ChatAttachment], access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let context = try resolve(access), conversation = context.state.conversation
        let dialect = adapter
        try claimOperation(operationID)
        guard !sending.contains(context.identity) else { throw HermesServiceError.staleConversation }
        let socket = try requireSelected(conversation)
        let owner = selectionGeneration, connectionOwner = connectionGeneration
        let queueObservation = state?.queueObservation
        guard attachments.count <= AttachmentLimits.count else { throw HermesServiceError.attachmentLimit }
        let files = try attachments.map { attachment -> UploadedFile in
            guard let token = attachment.stagingID, let file = uploads[token.uuidString], exactAttachment(file.attachment, attachment),
                  exact(file.profile, conversation.profileID), exact(file.stored, conversation.storedID) else { throw HermesServiceError.invalidAttachment }
            return file
        }
        guard files.reduce(0, { $0 + $1.bytes }) <= AttachmentLimits.totalBytes else { throw HermesServiceError.attachmentLimit }
        let prompt = ([text.trimmingCharacters(in: .whitespacesAndNewlines)] + files.compactMap(\.reference))
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !prompt.isEmpty || !files.isEmpty else { throw HermesServiceError.invalidResponse }
        let submission = operationID.uuidString
        let images = files.filter(\.nativeImage).map { HermesJSON.object(["path": .string($0.attachment.path), "mime": .string($0.attachment.mimeType)]) }
        let wireText = prompt.isEmpty ? "Please examine the attached image." : prompt
        if adapter == .authority {
            guard let configuration else { throw HermesServiceError.disconnected }
            try journal.record(submission, connection: configuration.id, profile: conversation.profileID, stored: conversation.storedID)
        }
        // Authority publishes an idle admission as queued just before starting it.
        if dialect == .authority, let current = state?.conversation, !current.isWorking, current.queuedMessages.isEmpty,
           current.pendingRequests.isEmpty, state?.startingSubmission == nil {
            state?.startingSubmission = .init(id: submission)
        }
        sending.insert(context.identity); defer { sending.remove(context.identity) }
        let optimisticID = "submission:" + submission
        state?.conversation.messages.append(ChatMessage(id: optimisticID, role: .user, text: text, timestamp: Date(),
            attachments: attachments, transientID: UUID()))
        state?.optimistic.append(optimisticID)
        emitConversation()
        do {
            let reply = try await socket.call("prompt.submit", adapter.submit(conversation, text: wireText, submission: submission, images: images),
                mutation: true, validate: { try self.validate(access); self.freshEmpty.remove(context.identity) })
            var durability = JournalDurability.saved
            var admissionID: String?
            if dialect == .authority {
                guard let admission = reply["admission_id"].nonempty,
                      exact(reply["ref"]["session_id"].text, conversation.id),
                      exact(reply["ref"]["profile_id"].text, context.state.profileIdentity),
                      ["queued", "started", "unknown", "terminal"].contains(reply["status"].text ?? "") else { throw HermesServiceError.uncertain }
                admissionID = admission
                do { try journal.acknowledge(submission, admission: admission) } catch { durability = .needsLocalRepair }
                if reply["status"].text == "unknown" { throw HermesServiceError.uncertain }
                if reply["status"].text == "queued", isSelected(context) {
                    state?.confirmQueuedReceipt(admission: admission, text: wireText, submission: submission, observation: queueObservation)
                    emitConversation()
                }
                if let generation = reply["execution_generation"].integer,
                   isSelected(context), generation >= (state?.generation ?? 0) { state?.generation = generation; emitConversation() }
            } else {
                guard ["streaming", "queued"].contains(reply["status"].text ?? "") else { throw HermesServiceError.uncertain }
                if reply["status"].text == "queued", isSelected(context), state?.queueObservation == queueObservation {
                    // The sidecar ACK carries no admission ID. Keep a local, read-only
                    // entry until an explicit queue projection or refreshed snapshot.
                    state?.conversation.queuedMessages.append(QueuedMessage(id: "sidecar-submission:" + submission,
                        text: wireText, submissionID: submission))
                    emitConversation()
                }
            }
            for attachment in attachments { if let id = attachment.stagingID { uploads[id.uuidString] = nil } }
            onEvent?(.botsChanged)
            // The receipt is admission, not completion. State comes from stream/snapshot.
            if reply["status"].text == "terminal", exact(state?.startingSubmission?.id, submission) {
                state?.startingSubmission = nil
            }
            if reply["status"].text == "terminal", isSelected(context) { scheduleRefresh() }
            return receipt(operationID, context: context, admission: admissionID, journal: durability)
        } catch {
            if (error as? HermesServiceError) != .uncertain, exact(state?.startingSubmission?.id, submission) {
                state?.startingSubmission = nil
            }
            if owner == selectionGeneration, connectionOwner == connectionGeneration {
                if (error as? HermesServiceError) == .uncertain {
                    state?.note(HermesServiceError.uncertain.localizedDescription, id: "uncertain:" + submission)
                    emitConversation(); scheduleRefresh()
                } else if (error as? HermesServiceError) == .staleConversation || Self.rejectedMutation(error) {
                    state?.conversation.messages.removeAll { $0.id == optimisticID }
                    state?.optimistic.removeAll { $0 == optimisticID }; emitConversation()
                }
            }
            throw error
        }
    }

    private func steer(text: String, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let context = try resolve(access), conversation = context.state.conversation
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state?.conversation.isWorking == true else { throw HermesServiceError.steeringUnavailable }
        try claimOperation(operationID)
        guard !sending.contains(context.identity) else { throw HermesServiceError.staleConversation }
        let socket = try requireSelected(conversation)
        let dialect = adapter, owner = selectionGeneration, connectionOwner = connectionGeneration
        var params = try dialect.control(conversation, generation: context.state.generation)
        params["text"] = .string(text)
        sending.insert(context.identity); defer { sending.remove(context.identity) }
        let reply: HermesJSON
        do {
            reply = try await socket.call("session.steer", params, mutation: true, validate: {
                try self.validate(access)
                guard self.state?.conversation.isWorking == true else { throw HermesServiceError.steeringUnavailable }
            })
        } catch {
            if (error as? HermesServiceError) == .staleGeneration,
               owner == selectionGeneration, connectionOwner == connectionGeneration { scheduleRefresh() }
            throw error
        }
        // A correction receipt confirms delivery to this turn, not a new admission.
        if dialect == .authority {
            guard reply["execution_generation"].integer == context.state.generation else { throw HermesServiceError.uncertain }
        }
        if reply["status"].text == "rejected" { throw HermesServiceError.steeringUnavailable }
        guard reply["status"].text == "queued" else { throw HermesServiceError.uncertain }
        if isSelected(context) {
            state?.conversation.messages.append(ChatMessage(id: "steer:" + operationID.uuidString, role: .user, text: text,
                timestamp: .now, transientID: UUID()))
            emitConversation()
        }
        onEvent?(.botsChanged)
        return receipt(operationID, context: context)
    }

    public func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        try Task.checkCancellation()
        return try await Task { try await self.interrupt(access: access, operationID: operationID) }.value
    }

    func interrupt(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let context = try resolve(access), conversation = context.state.conversation
        let dialect = adapter
        try claimOperation(operationID)
        let socket = try requireSelected(conversation), owner = selectionGeneration, connectionOwner = connectionGeneration
        let params = try dialect.control(conversation, generation: context.state.generation)
        var acknowledged = false
        defer {
            if !acknowledged, pendingStopObservation?.operation == operationID { pendingStopObservation = nil }
        }
        let reply: HermesJSON
        do {
            reply = try await socket.call("session.interrupt", params, mutation: true,
                validate: {
                    try self.validate(access)
                    guard let current = self.state, current.conversation.isWorking else { return }
                    self.pendingStopObservation = HermesStopObservation(operation: operationID,
                        connection: connectionOwner, selection: owner, identity: context.identity,
                        runtime: current.conversation.id, epoch: current.epoch,
                        profileIdentity: current.profileIdentity, generation: current.generation,
                        admission: current.activeAdmission, sequenceBeforeDispatch: current.conversation.lastSequence)
                })
        } catch {
            if (error as? HermesServiceError) == .staleGeneration, owner == selectionGeneration,
               connectionOwner == connectionGeneration { scheduleRefresh() }
            throw error
        }
        if dialect == .authority {
            guard exact(reply["ref"]["session_id"].text, conversation.id),
                  reply["ref"]["profile_id"].text.map({ exact($0, context.state.profileIdentity) }) != false,
                  reply["execution_generation"].integer != nil else { throw HermesServiceError.uncertain }
        } else if !["interrupted", "not_interrupted"].contains(reply["status"].text ?? "") { throw HermesServiceError.uncertain }
        acknowledged = true
        if isSelected(context) { scheduleRefresh() }
        return receipt(operationID, context: context)
    }

    public func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        try Task.checkCancellation()
        return try await Task { try await self.answer(request, response: response, access: access, operationID: operationID) }.value
    }

    func answer(_ request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let context = try resolve(access), conversation = context.state.conversation
        try claimOperation(operationID)
        let socket = try requireSelected(conversation), owner = selectionGeneration, connectionOwner = connectionGeneration
        guard !answering.contains(accessKey(access, request.id)), state?.conversation.pendingRequests.contains(where: { $0.hasSameWireRevision(as: request) }) == true,
              let route = state?.routes[request.id] else { throw HermesServiceError.staleConversation }
        guard route.kind != .unsupported else { throw HermesServiceError.unsupportedRequest }
        let answer: String
        switch response {
        case .choice(let id):
            guard let choice = request.choices.first(where: { exact($0.id, id) }) else { throw HermesServiceError.invalidResponse }
            answer = request.kind == .approval ? choice.id : choice.label
        case .text(let text):
            guard request.kind == .question, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw HermesServiceError.invalidResponse }
            guard text.utf8.count <= 16_384 else { throw HermesServiceError.responseTooLong }
            answer = text
        }
        var params: [String: HermesJSON]
        let method: String
        if route.authority {
            params = try adapter.control(conversation, generation: route.generation)
            params["prompt_id"] = .string(route.hostID)
            if route.kind == .approval { method = "approval.respond"; params["choice"] = .string(answer) }
            else { method = "clarify.respond"; params["answer"] = .string(answer) }
        } else {
            switch route.kind {
            case .approval:
                method = "approval.respond"
                params = ["session_id": .string(conversation.id), "request_id": .string(route.hostID), "choice": .string(answer)]
            case .batch(let qid):
                method = "clarify.lock"
                params = ["request_id": .string(route.hostID), "question_id": .string(qid), "answer": .string(answer)]
            case .question:
                // Authority's single-question requests are projected as fenced prompts.
                // Do not guess an RPC for a future unprojected authority server request.
                guard adapter == .sidecar else { throw HermesServiceError.unsupportedRequest }
                method = "request.answer"
                params = ["id": .string(route.hostID), "result": .object(["answer": .string(answer)])]
            case .unsupported: throw HermesServiceError.unsupportedRequest
            }
            params["profile"] = .string(conversation.profileID)
        }
        let answerKey = accessKey(access, request.id)
        answering.insert(answerKey); defer { answering.remove(answerKey) }
        let reply: HermesJSON
        do {
            reply = try await socket.call(method, params, mutation: true, validate: {
                try self.validate(access)
                guard self.state?.routes[request.id] == route,
                      self.state?.conversation.pendingRequests.contains(where: { $0.hasSameWireRevision(as: request) }) == true else { throw HermesServiceError.staleConversation }
            })
        } catch {
            if (error as? HermesServiceError) == .staleGeneration, owner == selectionGeneration,
               connectionOwner == connectionGeneration { scheduleRefresh() }
            throw error
        }
        let confirmed: Bool
        if route.authority { confirmed = ["resolved", "already_resolved"].contains(reply["status"].text ?? "") && exact(reply["prompt_id"].text, route.hostID) }
        else if route.kind == .approval { confirmed = (reply["resolved"].integer ?? -1) >= 0 }
        else if case .batch = route.kind { confirmed = ["ok", "expired", "locked", "resolved"].contains(reply["status"].text ?? "") }
        else { confirmed = ["ok", "expired"].contains(reply["status"].text ?? "") }
        guard confirmed else { throw HermesServiceError.uncertain }
        if isSelected(context), state?.routes[request.id] == route,
           state?.conversation.pendingRequests.contains(where: { $0.hasSameWireRevision(as: request) }) == true {
            state?.removeRequest(request.id); emitConversation()
        }
        onEvent?(.botsChanged)
        return receipt(operationID, context: context)
    }

    public func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        try Task.checkCancellation()
        return try await Task { try await self.stage(data: data, filename: filename, mimeType: mimeType, access: access) }.value
    }

    func stage(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        let context = try resolve(access), conversation = context.state.conversation
        let socket = try requireSelected(conversation)
        let prepared = try await Task.detached { try HermesAttachment.prepare(data: data, filename: filename, mime: mimeType) }.value
        try validate(access)
        let encoded = await Task.detached { prepared.data.base64EncodedString() }.value
        try validate(access)
        let reply: HermesJSON, reference: String?, nativeImage: Bool
        let path: String, resolvedMime: String
        if prepared.image, adapter == .authority {
            reply = try await socket.call("image.attach_bytes", ["profile": .string(conversation.profileID),
                "session_id": .string(conversation.id), "filename": .string(prepared.name), "content_base64": .string(encoded)], mutation: true,
                validate: { try self.validate(access) })
            guard reply["attached"].flag == true, let mime = reply["mime"].nonempty,
                  ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) else { throw HermesServiceError.invalidAttachment }
            path = try HermesAttachment.hostPath(reply["path"].text)
            resolvedMime = mime; reference = nil; nativeImage = true
        } else if prepared.image {
            guard let http else { throw HermesServiceError.disconnected }
            reply = try await http.json("api/chat/image-upload", body: ["filename": .string(prepared.name),
                "data_url": .string("data:" + prepared.mime + ";base64," + encoded)],
                query: [URLQueryItem(name: "profile", value: conversation.profileID)], validate: { try self.validate(access) })
            guard reply["ok"].flag == true else { throw HermesServiceError.invalidAttachment }
            path = try HermesAttachment.hostPath(reply["path"].text)
            reference = HermesAttachment.imageReference(path); resolvedMime = prepared.mime; nativeImage = false
        } else {
            reply = try await socket.call("file.attach", ["profile": .string(conversation.profileID), "session_id": .string(conversation.id),
                "name": .string(UUID().uuidString + "-" + prepared.name), "data_url": .string("data:" + prepared.mime + ";base64," + encoded)], mutation: true,
                validate: { try self.validate(access) })
            guard reply["attached"].flag == true, let ref = reply["ref_text"].nonempty, ref.hasPrefix("@file:"),
                  !ref.contains(where: { $0.isNewline || $0 == "\0" }) else { throw HermesServiceError.invalidAttachment }
            path = try HermesAttachment.hostPath(reply["path"].text)
            reference = ref; resolvedMime = prepared.mime; nativeImage = false
        }
        try validate(access)
        let token = UUID()
        let attachment = ChatAttachment(name: prepared.name, path: path, mimeType: resolvedMime, byteCount: prepared.data.count, stagingID: token)
        uploads[token.uuidString] = UploadedFile(attachment: attachment, profile: conversation.profileID, stored: conversation.storedID,
                                     bytes: prepared.data.count, reference: reference, nativeImage: nativeImage)
        return attachment
    }

    public func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        let context = try resolve(access), conversation = context.state.conversation
        try Task.checkCancellation()
        _ = try requireSelected(conversation)
        guard let http else { throw HermesServiceError.disconnected }
        let result = try await http.downloadArtifact(path: attachment.path, profile: conversation.profileID, sessionID: conversation.storedID)
        try Task.checkCancellation()
        try validate(access)
        return result
    }

    static func rejectedMutation(_ error: any Error) -> Bool {
        if case HermesServiceError.rejected = error { true } else { false }
    }
}
