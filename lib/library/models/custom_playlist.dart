import 'dart:convert';

class CustomPlaylist {
  final String id;
  final String name;
  final List<int> songIds;

  CustomPlaylist({
    required this.id,
    required this.name,
    List<int>? songIds,
  }) : songIds = songIds ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'songIds': songIds,
      };

  factory CustomPlaylist.fromJson(Map<String, dynamic> json) {
    final rawIds = json['songIds'];
    return CustomPlaylist(
      id: json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'Sin nombre',
      songIds: rawIds is List
          ? rawIds.whereType<num>().map((e) => e.toInt()).toList()
          : <int>[],
    );
  }

  CustomPlaylist copyWith({String? name, List<int>? songIds}) => CustomPlaylist(
        id: id,
        name: name ?? this.name,
        songIds: songIds != null ? List<int>.from(songIds) : List<int>.from(this.songIds),
      );

  static List<CustomPlaylist> decodeList(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! List) return <CustomPlaylist>[];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(CustomPlaylist.fromJson)
        .toList();
  }

  static String encodeList(List<CustomPlaylist> playlists) {
    return jsonEncode(playlists.map((p) => p.toJson()).toList());
  }
}
