class User {
  final String id;
  final String? email;
  final String role;
  final String name;
  final String? phone;
  final String? avatarUrl;

  const User({
    required this.id,
    this.email,
    required this.role,
    required this.name,
    this.phone,
    this.avatarUrl,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'].toString(),
      email: json['email'] as String?,
      role: json['role'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String?,
      avatarUrl: (json['avatarUrl'] ?? json['avatar_url']) as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'role': role,
      'name': name,
      'phone': phone,
      'avatar_url': avatarUrl,
    };
  }

  User copyWith({
    String? id,
    String? email,
    String? role,
    String? name,
    String? phone,
    String? avatarUrl,
  }) {
    return User(
      id: id ?? this.id,
      email: email ?? this.email,
      role: role ?? this.role,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }
}
