import '../utils/num_util.dart';

class Booking {
  final String id;
  final String? venueId;
  final String? playerId;
  final String? slotId;
  final String status;
  final double? totalAmount;
  final double? depositAmount;
  final String? qrCodeHash;
  final String? createdAt;
  final String? venueName;
  final String? city;
  final String? imageUrl;
  final String? slotDate;
  final String? startTime;
  final String? endTime;

  const Booking({
    required this.id,
    this.venueId,
    this.playerId,
    this.slotId,
    required this.status,
    this.totalAmount,
    this.depositAmount,
    this.qrCodeHash,
    this.createdAt,
    this.venueName,
    this.city,
    this.imageUrl,
    this.slotDate,
    this.startTime,
    this.endTime,
  });

  factory Booking.fromJson(Map<String, dynamic> json) {
    return Booking(
      id: json['id'] as String,
      venueId: json['venue_id'] as String?,
      playerId: json['player_id'] as String?,
      slotId: json['slot_id'] as String?,
      status: json['status'] as String? ?? 'pending',
      totalAmount: asNumOrNull(json['total_amount']),
      depositAmount: asNumOrNull(json['deposit_amount']),
      qrCodeHash: json['qr_code_hash'] as String?,
      createdAt: json['created_at'] as String?,
      venueName: json['venue_name'] as String?,
      city: json['city'] as String?,
      imageUrl: json['image_url'] as String?,
      slotDate: json['date'] as String?,
      startTime: json['start_time'] as String?,
      endTime: json['end_time'] as String?,
    );
  }
}
