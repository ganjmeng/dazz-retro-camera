enum RenderStyleMode {
  replica,
  smart,
}

extension RenderStyleModeX on RenderStyleMode {
  String get storageValue {
    switch (this) {
      case RenderStyleMode.replica:
        return 'replica';
      case RenderStyleMode.smart:
        return 'smart';
    }
  }

  static RenderStyleMode fromStorage(String? raw) {
    switch (raw) {
      case 'smart':
        return RenderStyleMode.smart;
      case 'replica':
      default:
        return RenderStyleMode.replica;
    }
  }
}
