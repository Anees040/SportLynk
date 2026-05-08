class Venue {
  final String id;
  final String name;
  final String? description;
  final String? sportType;
  final String? city;
  final String? address;
  final double? latitude;
  final double? longitude;
  final double? basePrice;
  final double? currentPrice;
  final String? imageUrl;
  final bool isActive;

  const Venue({
    required this.id,
    required this.name,
    this.description,
    this.sportType,
    this.city,
    this.address,
    this.latitude,
    this.longitude,
    this.basePrice,
    this.currentPrice,
    this.imageUrl,
    this.isActive = true,
  });

  factory Venue.fromJson(Map<String, dynamic> json) {
    return Venue(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      sportType: json['sport_type'] as String?,
      city: json['city'] as String?,
      address: json['address'] as String?,
      latitude: _toDouble(json['latitude']),
      longitude: _toDouble(json['longitude']),
      basePrice: _toDouble(json['base_price']),
      currentPrice: _toDouble(json['current_price']),
      imageUrl: json['image_url'] as String?,
      isActive: json['is_active'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'sport_type': sportType,
      'city': city,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'base_price': basePrice,
      'current_price': currentPrice,
      'image_url': imageUrl,
      'is_active': isActive,
    };
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
