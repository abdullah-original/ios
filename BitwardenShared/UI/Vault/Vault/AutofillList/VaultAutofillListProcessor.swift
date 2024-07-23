import AuthenticationServices
import BitwardenSdk

// MARK: - VaultAutofillListProcessor

/// The processor used to manage state and handle actions for the autofill list screen.
///
class VaultAutofillListProcessor: StateProcessor<
    VaultAutofillListState,
    VaultAutofillListAction,
    VaultAutofillListEffect
> {
    // MARK: Types

    typealias Services = HasAuthRepository
        & HasClientService
        & HasErrorReporter
        & HasEventService
        & HasFido2CredentialStore
        & HasFido2UserInterfaceHelper
        & HasPasteboardService
        & HasVaultRepository

    // MARK: Private Properties

    /// A delegate used to communicate with the app extension.
    private weak var appExtensionDelegate: AppExtensionDelegate?

    /// A helper that handles autofill for a selected cipher.
    private let autofillHelper: AutofillHelper

    /// The `Coordinator` that handles navigation.
    private var coordinator: AnyCoordinator<VaultRoute, AuthAction>

    /// The services used by this processor.
    private var services: Services

    // MARK: Initialization

    /// Initialize a `VaultAutofillListProcessor`.
    ///
    /// - Parameters:
    ///   - appExtensionDelegate: A delegate used to communicate with the app extension.
    ///   - coordinator: The coordinator that handles navigation.
    ///   - services: The services used by this processor.
    ///   - state: The initial state of the processor.
    ///
    init(
        appExtensionDelegate: AppExtensionDelegate?,
        coordinator: AnyCoordinator<VaultRoute, AuthAction>,
        services: Services,
        state: VaultAutofillListState
    ) {
        self.appExtensionDelegate = appExtensionDelegate
        autofillHelper = AutofillHelper(
            appExtensionDelegate: appExtensionDelegate,
            coordinator: coordinator,
            services: services
        )
        self.coordinator = coordinator
        self.services = services
        super.init(state: state)
    }

    // MARK: Methods

    override func perform(_ effect: VaultAutofillListEffect) async {
        switch effect {
        case let .vaultItemTapped(vaultItem):
            switch vaultItem.itemType {
            case let .cipher(cipher, fido2CredentialAutofillView):
                if #available(iOSApplicationExtension 17.0, *),
                   fido2CredentialAutofillView != nil {
                    await onCipherForFido2CredentialPicked(cipher: cipher)
                } else {
                    await autofillHelper.handleCipherForAutofill(cipherView: cipher) { [weak self] toastText in
                        self?.state.toast = Toast(text: toastText)
                    }
                }
            case .group:
                return
            case .totp:
                return
            }
        case .initFido2:
            if #available(iOSApplicationExtension 17.0, *) {
                await initFido2State()
            }
        case .loadData:
            await refreshProfileState()
        case let .profileSwitcher(profileEffect):
            await handle(profileEffect)
        case let .search(text):
            await searchVault(for: text)
        case .streamAutofillItems:
            await streamAutofillItems()
        }
    }

    override func receive(_ action: VaultAutofillListAction) {
        switch action {
        case .addTapped:
            state.profileSwitcherState.setIsVisible(false)
            coordinator.navigate(
                to: .addItem(
                    allowTypeSelection: false,
                    group: .login,
                    newCipherOptions: createNewCipherOptions()
                )
            )
        case .cancelTapped:
            appExtensionDelegate?.didCancel()
        case let .profileSwitcher(action):
            handle(action)
        case let .searchStateChanged(isSearching: isSearching):
            guard isSearching else { return }
            state.searchText = ""
            state.ciphersForSearch = []
            state.showNoResults = false
            state.profileSwitcherState.isVisible = false
        case let .searchTextChanged(newValue):
            state.searchText = newValue
        case let .toastShown(newValue):
            state.toast = newValue
        }
    }

    // MARK: Private Methods

    /// Creates a `NewCipherOptions` based on the context flow.
    func createNewCipherOptions() -> NewCipherOptions {
        if let fido2AppExtensionDelegate = appExtensionDelegate as? Fido2AppExtensionDelegate,
           fido2AppExtensionDelegate.isCreatingFido2Credential,
           let fido2CredentialNewView = services.fido2UserInterfaceHelper.fido2CredentialNewView {
            return NewCipherOptions(
                name: fido2CredentialNewView.rpName,
                uri: fido2CredentialNewView.rpId,
                username: fido2CredentialNewView.userName
            )
        }
        return NewCipherOptions(uri: appExtensionDelegate?.uri)
    }

    /// Creates the vault list sections from given ciphers and search text.
    /// This is to centralize sections creation from loading and searching.
    ///
    /// - Parameters:
    ///   - ciphers: The ciphers to create the sections, either load or search results.
    ///   - searchText: The current search text.
    ///
    private func createVaultListSections(
        from ciphers: [CipherView],
        searchText: String?
    ) async throws -> [VaultListSection] {
        var sections = [VaultListSection]()
        if #available(iOSApplicationExtension 17.0, *),
           let fido2Section = try await loadFido2Section(
               searchText: searchText,
               searchResults: searchText != nil ? ciphers : nil
           ) {
            sections.append(fido2Section)
        } else if ciphers.isEmpty {
            return []
        }

        let sectionName = getPasswordsSectionName(searchText: searchText)

        sections.append(
            VaultListSection(
                id: sectionName,
                items: ciphers.compactMap { .init(cipherView: $0) },
                name: sectionName
            )
        )
        return sections
    }

    /// Gets the passwords vault list section name depending on the context.
    ///
    /// - Parameter searchText: The current search text.
    ///
    private func getPasswordsSectionName(searchText: String?) -> String {
        if let fido2Delegate = appExtensionDelegate as? Fido2AppExtensionDelegate,
           !fido2Delegate.isAutofillingFido2CredentialFromList,
           !fido2Delegate.isCreatingFido2Credential {
            return ""
        }

        if let searchText {
            return Localizations.passwordsForX(searchText)
        }

        if let uri = appExtensionDelegate?.uri {
            return Localizations.passwordsForX(uri)
        }

        return Localizations.passwords
    }

    /// Handles receiving a `ProfileSwitcherAction`.
    ///
    /// - Parameter action: The `ProfileSwitcherAction` to handle.
    ///
    private func handle(_ profileSwitcherAction: ProfileSwitcherAction) {
        switch profileSwitcherAction {
        case let .accessibility(accessibilityAction):
            switch accessibilityAction {
            case .logout:
                // No-op: account logout not supported in the extension.
                break
            }
        default:
            handleProfileSwitcherAction(profileSwitcherAction)
        }
    }

    /// Handles receiving a `ProfileSwitcherEffect`.
    ///
    /// - Parameter action: The `ProfileSwitcherEffect` to handle.
    ///
    private func handle(_ profileSwitcherEffect: ProfileSwitcherEffect) async {
        switch profileSwitcherEffect {
        case let .accessibility(accessibilityAction):
            switch accessibilityAction {
            case .lock:
                // No-op: account lock not supported in the extension.
                break
            default:
                await handleProfileSwitcherEffect(profileSwitcherEffect)
            }
        default:
            await handleProfileSwitcherEffect(profileSwitcherEffect)
        }
    }

    /// Searches the list of ciphers for those matching the search term.
    ///
    private func searchVault(for searchText: String) async {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.ciphersForSearch = []
            state.showNoResults = false
            return
        }
        do {
            let searchResult = try await services.vaultRepository.searchCipherAutofillPublisher(
                searchText: searchText,
                filterType: .allVaults
            )
            for try await ciphers in searchResult {
                state.ciphersForSearch = try await createVaultListSections(from: ciphers, searchText: searchText)
                state.showNoResults = ciphers.isEmpty
            }
        } catch {
            state.ciphersForSearch = []
            coordinator.showAlert(.defaultAlert(title: Localizations.anErrorHasOccurred))
            services.errorReporter.log(error: error)
        }
    }

    /// Streams the list of autofill items.
    ///
    private func streamAutofillItems() async {
        do {
            for try await ciphers in try await services.vaultRepository.ciphersAutofillPublisher(
                uri: appExtensionDelegate?.uri
            ) {
                state.vaultListSections = try await createVaultListSections(from: ciphers, searchText: nil)
            }
        } catch {
            coordinator.showAlert(.defaultAlert(title: Localizations.anErrorHasOccurred))
            services.errorReporter.log(error: error)
        }
    }
}

// MARK: - ProfileSwitcherHandler

extension VaultAutofillListProcessor: ProfileSwitcherHandler {
    var allowLockAndLogout: Bool {
        false
    }

    var profileServices: ProfileServices {
        services
    }

    var profileSwitcherState: ProfileSwitcherState {
        get {
            state.profileSwitcherState
        }
        set {
            state.profileSwitcherState = newValue
        }
    }

    var shouldHideAddAccount: Bool {
        true
    }

    var toast: Toast? {
        get {
            state.toast
        }
        set {
            state.toast = newValue
        }
    }

    func handleAuthEvent(_ authEvent: AuthEvent) async {
        guard case let .action(authAction) = authEvent else { return }
        await coordinator.handleEvent(authAction)
    }

    func showAddAccount() {
        // No-Op for the VaultAutofillListProcessor.
    }

    func showAlert(_ alert: Alert) {
        coordinator.showAlert(alert)
    }
}

// MARK: - Fido2UserInterfaceHelperDelegate

extension VaultAutofillListProcessor: Fido2UserInterfaceHelperDelegate {
    var isAutofillingFromList: Bool {
        guard let fido2AppExtensionDelegate = appExtensionDelegate as? Fido2AppExtensionDelegate,
              fido2AppExtensionDelegate.isAutofillingFido2CredentialFromList else {
            return false
        }
        return true
    }

    func onNeedsUserInteraction() async throws {
        // No-Op for this processor.
    }

    func showAlert(_ alert: Alert, onDismissed: (() -> Void)?) {
        coordinator.showAlert(alert, onDismissed: onDismissed)
    }
}

// MARK: - Fido2 flows

@available(iOSApplicationExtension 17.0, *)
extension VaultAutofillListProcessor {
    // MARK: Methods

    /// Initializes Fido2 state and flows if needed.
    private func initFido2State() async {
        guard let fido2AppExtensionDelegate = appExtensionDelegate as? Fido2AppExtensionDelegate else {
            return
        }

        switch fido2AppExtensionDelegate.extensionMode {
        case let .registerFido2Credential(request):
            if let request = request as? ASPasskeyCredentialRequest,
               let credentialIdentity = request.credentialIdentity as? ASPasskeyCredentialIdentity {
                services.fido2UserInterfaceHelper.setupDelegate(fido2UserInterfaceHelperDelegate: self)

                await handleFido2CredentialCreation(
                    fido2appExtensionDelegate: fido2AppExtensionDelegate,
                    request: request,
                    credentialIdentity: credentialIdentity
                )
            }
        case let .autofillFido2VaultList(serviceIdentifiers, fido2RequestParameters):
            state.isAutofillingFido2List = true
            state.emptyViewMessage = Localizations.noItemsToList
            services.fido2UserInterfaceHelper.setupDelegate(fido2UserInterfaceHelperDelegate: self)

            await handleFido2CredentialAutofill(
                fido2appExtensionDelegate: fido2AppExtensionDelegate,
                serviceIdentifiers: serviceIdentifiers,
                fido2RequestParameters: fido2RequestParameters
            )
        default:
            break
        }
    }

    /// Handles Fido2 credential creation flow starting a request and completing the registration.
    /// - Parameters:
    ///   - fido2appExtensionDelegate: The app extension delegate from the Autofill extension.
    ///   - request: The passkey credential request to create the Fido2 credential.
    ///   - credentialIdentity: The passkey credential identity from the request to create the Fido2 credential.
    func handleFido2CredentialAutofill(
        fido2appExtensionDelegate: Fido2AppExtensionDelegate,
        serviceIdentifiers: [ASCredentialServiceIdentifier],
        fido2RequestParameters: PasskeyCredentialRequestParameters
    ) async {
        do {
            let request = GetAssertionRequest(
                rpId: fido2RequestParameters.relyingPartyIdentifier,
                clientDataHash: fido2RequestParameters.clientDataHash,
                allowList: fido2RequestParameters.allowedCredentials.map { credentialId in
                    PublicKeyCredentialDescriptor(
                        ty: "public-key",
                        id: credentialId,
                        transports: nil
                    )
                },
                options: Options(
                    rk: false,
                    uv: BitwardenSdk.Uv(preference: fido2RequestParameters.userVerificationPreference)
                ),
                extensions: nil
            )

            #if DEBUG
            Fido2DebuggingReportBuilder.builder.withGetAssertionRequest(request)
            #endif

            let assertionResult = try await services.clientService.platform().fido2()
                .authenticator(
                    userInterface: services.fido2UserInterfaceHelper,
                    credentialStore: services.fido2CredentialStore
                )
                .getAssertion(request: request)

            #if DEBUG
            Fido2DebuggingReportBuilder.builder.withGetAssertionResult(.success(assertionResult))
            #endif

            fido2appExtensionDelegate.completeAssertionRequest(assertionCredential: ASPasskeyAssertionCredential(
                userHandle: assertionResult.userHandle,
                relyingParty: fido2RequestParameters.relyingPartyIdentifier,
                signature: assertionResult.signature,
                clientDataHash: fido2RequestParameters.clientDataHash,
                authenticatorData: assertionResult.authenticatorData,
                credentialID: assertionResult.credentialId
            ))
        } catch {
            #if DEBUG
            Fido2DebuggingReportBuilder.builder.withGetAssertionResult(.failure(error))
            #endif
            services.fido2UserInterfaceHelper.pickedCredentialForAuthentication(result: .failure(error))
            services.errorReporter.log(error: error)
        }
    }

    /// Handles Fido2 credential creation flow starting a request and completing the registration.
    /// - Parameters:
    ///   - fido2appExtensionDelegate: The app extension delegate from the Autofill extension.
    ///   - request: The passkey credential request to create the Fido2 credential.
    ///   - credentialIdentity: The passkey credential identity from the request to create the Fido2 credential.
    func handleFido2CredentialCreation(
        fido2appExtensionDelegate: Fido2AppExtensionDelegate,
        request: ASPasskeyCredentialRequest,
        credentialIdentity: ASPasskeyCredentialIdentity
    ) async {
        do {
            let request = MakeCredentialRequest(
                clientDataHash: request.clientDataHash,
                rp: PublicKeyCredentialRpEntity(
                    id: credentialIdentity.relyingPartyIdentifier,
                    name: credentialIdentity.relyingPartyIdentifier
                ),
                user: PublicKeyCredentialUserEntity(
                    id: credentialIdentity.userHandle,
                    displayName: credentialIdentity.userName,
                    name: credentialIdentity.userName
                ),
                pubKeyCredParams: request.getPublicKeyCredentialParams(),
                excludeList: nil,
                options: Options(
                    rk: true,
                    uv: Uv(preference: request.userVerificationPreference)
                ),
                extensions: nil
            )
            let createdCredential = try await services.clientService.platform().fido2()
                .authenticator(
                    userInterface: services.fido2UserInterfaceHelper,
                    credentialStore: services.fido2CredentialStore
                )
                .makeCredential(request: request)

            fido2appExtensionDelegate.completeRegistrationRequest(
                asPasskeyRegistrationCredential: ASPasskeyRegistrationCredential(
                    relyingParty: credentialIdentity.relyingPartyIdentifier,
                    clientDataHash: request.clientDataHash,
                    credentialID: createdCredential.credentialId,
                    attestationObject: createdCredential.attestationObject
                )
            )
        } catch {
            services.fido2UserInterfaceHelper.pickedCredentialForCreation(result: .failure(error))
            services.errorReporter.log(error: error)
        }
    }

    func loadFido2Section(
        searchText: String? = nil,
        searchResults: [CipherView]? = nil
    ) async throws -> VaultListSection? {
        guard let fido2Credentials = services.fido2UserInterfaceHelper.availableCredentialsForAuthentication,
              !fido2Credentials.isEmpty,
              let fido2Delegate = appExtensionDelegate as? Fido2AppExtensionDelegate,
              case let .autofillFido2VaultList(_, parameters) = fido2Delegate.extensionMode else {
            return nil
        }

        var filteredFido2Credentials = fido2Credentials
        if let searchResults {
            filteredFido2Credentials = filteredFido2Credentials.filter { cipher in
                searchResults.contains(where: { $0.id == cipher.id })
            }
        }

        guard !filteredFido2Credentials.isEmpty else {
            return nil
        }

        let fido2ListItems = try await filteredFido2Credentials
            .asyncMap { cipher in
                let fido2CredentialAutofillView = try await self.services.clientService
                    .platform()
                    .fido2()
                    .decryptFido2AutofillCredentials(cipherView: cipher)

                return VaultListItem(
                    cipherView: cipher,
                    fido2CredentialAutofillView: fido2CredentialAutofillView[0]
                )
            }.compactMap { $0 }

        return VaultListSection(
            id: Localizations.passkeysForX(searchText ?? parameters.relyingPartyIdentifier),
            items: fido2ListItems,
            name: Localizations.passkeysForX(searchText ?? parameters.relyingPartyIdentifier)
        )
    }

    /// Picks a cipher to use for the Fido2 process
    /// - Parameter cipher: Cipher to use.
    func onCipherForFido2CredentialPicked(cipher: CipherView) async {
        guard let fido2AppExtensionDelegate = appExtensionDelegate as? Fido2AppExtensionDelegate else {
            return
        }
        if fido2AppExtensionDelegate.isCreatingFido2Credential {
            services.fido2UserInterfaceHelper.pickedCredentialForCreation(
                result: .success(
                    CheckUserAndPickCredentialForCreationResult(
                        cipher: CipherViewWrapper(cipher: cipher),
                        // TODO: PM-9849 add user verification
                        checkUserResult: CheckUserResult(userPresent: true, userVerified: true)
                    )
                )
            )
        } else if fido2AppExtensionDelegate.isAutofillingFido2CredentialFromList {
            services.fido2UserInterfaceHelper.pickedCredentialForAuthentication(
                result: .success(cipher)
            )
        }
    }
} // swiftlint:disable:this file_length
