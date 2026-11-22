import YardletRemote

extension AppModelRemoteBridge {
    var supportsConnectorSetup: Bool { model?.connectorCenter != nil }

    func connectorSetup(_ request: RemoteConnectorSetupRequest, owner: String) async
        -> Result<RemoteConnectorSetupState, RemoteError> {
        guard let center = model?.connectorCenter else { return .failure(RemoteError(.unavailable)) }
        return connectorSetups.handle(request, owner: owner, center: center)
    }

    func cancelConnectorSetups(owner: String) async {
        connectorSetups.cancel(owner: owner)
    }
}
