import '../utils/num_util.dart';

class VenueSlot {
  final String id;
  final String venueId;
  final String date;
  final String startTime;
  final String endTime;
  final String status;
  final double price;

  const VenueSlot({
    required this.id,
    required this.venueId,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.status,
    required this.price,
  });

  factory VenueSlot.fromJson(Map<String, dynamic> json) {
    return VenueSlot(
      id: json['id'] as String,
      venueId: json['venue_id'] as String,
      date: json['date'] as String,
      startTime: json['start_time'] as String,
      endTime: json['end_time'] as String,
      status: json['status'] as String? ?? 'available',
      price: asNum(json['price']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'venue_id': venueId,
      'date': date,
      'start_time': startTime,
      'end_time': endTime,
      'status': status,
      'price': price,
    };
  }

  String get timeDisplay => '${_formatTime(startTime)} - ${_formatTime(endTime)}';

  bool get isAvailable => status == 'available';

  static String _formatTime(String time) {
    final parts = time.split(':');
    if (parts.isEmpty) return time;
    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = parts.length > 1 ? parts[1] : '00';
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '$displayHour:$minute $period';
  }
}
