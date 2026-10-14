class User {
  final String id;
  final String? email;
  final String role;
  final String name;
  final String? phone;
  final String? avatarUrl;

  /// The admin tier (migration 040). Meaningful only when [role] is `admin`:
  /// [isSuperAdmin] holds every power and may manage other admins; [permissions]
  /// is the subset a sub-admin has been granted (keys from the server's
  /// `/api/admin/permissions` catalog). Both default to the safe empty state, so a
  /// player, an owner, or an admin on a pre-040 server simply has no admin powers.
  final bool isSuperAdmin;
  final List<String> permissions;

  const User({
    required this.id,
    this.email,
    required this.role,
    required this.name,
    this.phone,
    this.avatarUrl,
    this.isSuperAdmin = false,
    this.permissions = const [],
  });

  /// True when this admin may use the surface guarded by [key] — the super admin
  /// passes every check, a sub-admin only its granted keys. The server enforces the
  /// same rule; this only decides what the UI offers.
  bool hasPermission(String key) => isSuperAdmin || permissions.contains(key);

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'].toString(),
      email: json['email'] as String?,
      role: json['role'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String?,
      avatarUrl: (json['avatarUrl'] ?? json['avatar_url']) as String?,
      isSuperAdmin: (json['isSuperAdmin'] ?? json['is_super_admin']) == true,
      permissions: (json['permissions'] as List?)
              ?.map((e) => '$e')
              .toList() ??
          const [],
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
      'isSuperAdmin': isSuperAdmin,
      'permissions': permissions,
    };
  }

  User copyWith({
    String? id,
    String? email,
    String? role,
    String? name,
    String? phone,
    String? avatarUrl,
    bool? isSuperAdmin,
    List<String>? permissions,
  }) {
    return User(
      id: id ?? this.id,
      email: email ?? this.email,
      role: role ?? this.role,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      isSuperAdmin: isSuperAdmin ?? this.isSuperAdmin,
      permissions: permissions ?? this.permissions,
    );
  }
}
