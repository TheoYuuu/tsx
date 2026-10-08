import Foundation

/// One completed translation from the shared account controller. The saved
/// generation binds the configuration to the user's explicitly selected account.
@MainActor
struct CodexTranslationProvider: TranslationProvider {
    let controller: CodexAccountController?
    let model: String
    let generation: String?

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard let controller else { throw CodexAccountError.runtimeUnavailable }
        guard let generation, CodexRuntimeSession.Request.canonicalGeneration(generation),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.utf8.count <= 256,
              !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CodexAccountError.invalidConfiguration }
        guard request.text.utf8.count <= 65_536 else { throw RemoteTranslationError.inputTooLarge }
        return try await controller.translate(request, model: model, generation: generation)
    }
}
