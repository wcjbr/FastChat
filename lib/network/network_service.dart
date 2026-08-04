export 'network_service_stub.dart' show ChatMessage, DiscoveredRoom;
export 'network_service_stub.dart'
    if (dart.library.io) 'network_service_io.dart'
    show ChatNetworkService;
