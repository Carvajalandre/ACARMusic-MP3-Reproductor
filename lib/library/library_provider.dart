import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/custom_playlist.dart';

class LibraryProvider extends ChangeNotifier {
  final OnAudioQuery _audioQuery = OnAudioQuery();

  List<SongModel> _songs = [];
  List<SongModel> _recentlyAdded = [];
  List<AlbumModel> _albums = [];
  List<ArtistModel> _artists = [];
  List<SongModel> _filteredSongs = [];
  final List<SongModel> _favorites = [];
  List<SongModel> _recentlyPlayed = [];
  List<CustomPlaylist> _playlists = [];
  Map<int, int> _playCounts = {};

  bool _isLoading = false;
  bool _hasPermission = false;
  String _searchQuery = '';

  static const String _favoritesKey = 'favorites_ids';
  static const String _recentlyKey = 'recently_played_ids';
  static const String _playlistsKey = 'custom_playlists_v2';
  static const String _playCountsKey = 'play_counts';
  static const String _playlistSortPrefix = 'playlist_sort_mode_';
  static const int _maxRecently = 50;

  SharedPreferences? _prefs;

  /// Catálogo completo, sin filtrar por búsqueda. La restauración de sesión
  /// y las colecciones inteligentes deben usar siempre esta lista.
  List<SongModel> get allSongs => _songs;
  /// Catálogo completo. La búsqueda es local de ExploreScreen y no debe
  /// filtrar el resto de pantallas (antes la Biblioteca se quedaba vacía).
  List<SongModel> get songs => _songs;
  List<SongModel> get searchResults => _filteredSongs;
  List<SongModel> get recentlyAdded => _recentlyAdded;
  List<AlbumModel> get albums => _albums;
  List<ArtistModel> get artists => _artists;
  List<SongModel> get favorites => _favorites;
  List<SongModel> get recentlyPlayed => _recentlyPlayed;
  List<CustomPlaylist> get playlists => _playlists;
  bool get isLoading => _isLoading;
  bool get hasPermission => _hasPermission;
  int get totalSongs => _songs.length;

  List<SongModel>? _mostPlayedCache;

  List<SongModel> get mostPlayed {
    final cached = _mostPlayedCache;
    if (cached != null) return cached;
    final sorted = [..._songs];
    sorted.sort(
        (a, b) => (_playCounts[b.id] ?? 0).compareTo(_playCounts[a.id] ?? 0));
    final result =
        sorted.where((s) => (_playCounts[s.id] ?? 0) > 0).take(50).toList();
    _mostPlayedCache = result;
    return result;
  }

  LibraryProvider() {
    _checkAndLoad();
  }

  Future<void> _checkAndLoad() async {
    _hasPermission = await _requestPermission();
    if (_hasPermission) await loadLibrary();
    notifyListeners();
  }

  /// Al arrancar, main.dart ya pidió los permisos. Aquí solo se comprueba.
  Future<bool> _requestPermission() async =>
      (await Permission.audio.isGranted) ||
      (await Permission.storage.isGranted);

  /// Reintento desde la pantalla de permisos (segundo punto autorizado).
  Future<void> requestPermissionAndLoad() async {
    final audioStatus = await Permission.audio.status;
    if (audioStatus.isPermanentlyDenied) return;
    var granted = audioStatus.isGranted;
    if (!granted) granted = (await Permission.audio.request()).isGranted;
    if (!granted) granted = (await Permission.storage.request()).isGranted;
    _hasPermission = granted;
    if (_hasPermission) await loadLibrary();
    notifyListeners();
  }

  Future<void> loadLibrary() async {
    _isLoading = true;
    notifyListeners();
    try {
      final rawSongs = await _audioQuery.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      _songs = rawSongs.where((s) {
        final path = s.data.toLowerCase();
        final dur = s.duration ?? 0;
        return s.isMusic == true &&
            !path.contains('whatsapp') &&
            !path.contains('telegram') &&
            !path.contains('voice') &&
            !path.contains('audio-record') &&
            dur >= 10000;
      }).toList();
      _mostPlayedCache = null;

      final byDate = [..._songs];
      byDate
          .sort((a, b) => (b.dateModified ?? 0).compareTo(a.dateModified ?? 0));
      _recentlyAdded = byDate.take(50).toList();

      _albums = await _audioQuery.queryAlbums(
        sortType: AlbumSortType.ALBUM,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
      );
      _artists = await _audioQuery.queryArtists(
        sortType: ArtistSortType.ARTIST,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
      );
      await _loadPersistedData();
    } catch (e) {
      debugPrint('Error cargando biblioteca: $e');
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadPersistedData() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('Error abriendo preferencias: $e');
      return;
    }
    final prefs = _prefs!;

    // Cada clave se carga de forma independiente: un valor corrupto no debe
    // descartar todos los favoritos y playlists del usuario.
    try {
      final byId = {for (final s in _songs) s.id.toString(): s};
      final favIds = prefs.getStringList(_favoritesKey) ?? [];
      _favorites
        ..clear()
        ..addAll(favIds.map((id) => byId[id]).whereType<SongModel>());

      final recentIds = prefs.getStringList(_recentlyKey) ?? [];
      _recentlyPlayed
        ..clear()
        ..addAll(recentIds.map((id) => byId[id]).whereType<SongModel>());
    } catch (e) {
      debugPrint('Error cargando favoritos/recientes: $e');
    }

    try {
      final playlistsJson = prefs.getString(_playlistsKey);
      if (playlistsJson != null) {
        _playlists = CustomPlaylist.decodeList(playlistsJson);
      }
    } catch (e) {
      debugPrint('Error cargando playlists: $e');
    }

    try {
      final playCountsJson = prefs.getString(_playCountsKey);
      if (playCountsJson != null) {
        final decoded = jsonDecode(playCountsJson);
        if (decoded is Map<String, dynamic>) {
          final counts = <int, int>{};
          for (final entry in decoded.entries) {
            final id = int.tryParse(entry.key);
            if (id == null) continue;
            counts[id] = entry.value is num ? (entry.value as num).toInt() : 0;
          }
          _playCounts = counts;
          _mostPlayedCache = null;
        }
      }
    } catch (e) {
      debugPrint('Error cargando contadores: $e');
    }
  }

  void search(String query) {
    _searchQuery = query.toLowerCase().trim();
    _filteredSongs = _searchQuery.isEmpty
        ? []
        : _songs
            .where((s) =>
                s.title.toLowerCase().contains(_searchQuery) ||
                (s.artist?.toLowerCase().contains(_searchQuery) ?? false) ||
                (s.album?.toLowerCase().contains(_searchQuery) ?? false))
            .toList();
    notifyListeners();
  }

  void clearSearch() {
    _searchQuery = '';
    _filteredSongs = [];
    notifyListeners();
  }

  void addToFavorites(SongModel song) {
    if (!_favorites.any((s) => s.id == song.id)) {
      _favorites.add(song);
      _saveFavorites();
      notifyListeners();
    }
  }

  void removeFromFavorites(SongModel song) {
    _favorites.removeWhere((s) => s.id == song.id);
    _saveFavorites();
    notifyListeners();
  }

  bool isFavorite(SongModel song) => _favorites.any((s) => s.id == song.id);

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _favoritesKey, _favorites.map((s) => s.id.toString()).toList());
  }

  void addToRecentlyPlayed(SongModel song) {
    _recentlyPlayed.removeWhere((s) => s.id == song.id);
    _recentlyPlayed.insert(0, song);
    if (_recentlyPlayed.length > _maxRecently) {
      _recentlyPlayed = _recentlyPlayed.sublist(0, _maxRecently);
    }
    _saveRecentlyPlayed();
    notifyListeners();
  }

  Future<void> _saveRecentlyPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _recentlyKey, _recentlyPlayed.map((s) => s.id.toString()).toList());
  }

  void incrementPlayCount(int songId) {
    _playCounts[songId] = (_playCounts[songId] ?? 0) + 1;
    _mostPlayedCache = null;
    _savePlayCounts();
    notifyListeners();
  }

  Future<void> _savePlayCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final map = _playCounts.map((k, v) => MapEntry(k.toString(), v));
    await prefs.setString(_playCountsKey, jsonEncode(map));
  }

  Future<void> createPlaylist(String name) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    _playlists.add(CustomPlaylist(id: id, name: name));
    await _savePlaylists();
    notifyListeners();
  }

  Future<void> deletePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    await _savePlaylists();
    notifyListeners();
  }

  Future<void> renamePlaylist(String id, String newName) async {
    final idx = _playlists.indexWhere((p) => p.id == id);
    if (idx >= 0) {
      _playlists[idx] = _playlists[idx].copyWith(name: newName);
      await _savePlaylists();
      notifyListeners();
    }
  }

  void addSongToPlaylist(String playlistId, int songId) {
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx >= 0 && !_playlists[idx].songIds.contains(songId)) {
      final updatedSongIds = List<int>.from(_playlists[idx].songIds)..insert(0, songId);
      _playlists[idx] = _playlists[idx].copyWith(songIds: updatedSongIds);
      _savePlaylists();
      notifyListeners();
    }
  }

  String getPlaylistSortMode(String playlistId) {
    return _prefs?.getString('$_playlistSortPrefix$playlistId') ?? 'custom';
  }

  Future<void> setPlaylistSortMode(String playlistId, String sortMode) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setString('$_playlistSortPrefix$playlistId', sortMode);
    notifyListeners();
  }

  void removeSongFromPlaylist(String playlistId, int songId) {
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx >= 0) {
      _playlists[idx].songIds.remove(songId);
      _savePlaylists();
      notifyListeners();
    }
  }

  void reorderPlaylist(String playlistId, List<int> newOrder) {
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx >= 0) {
      _playlists[idx] = _playlists[idx].copyWith(songIds: newOrder);
      _savePlaylists();
      notifyListeners();
    }
  }

  List<SongModel> getSongsForPlaylist(String playlistId) {
    final pl = _playlists.where((p) => p.id == playlistId).firstOrNull;
    if (pl == null) return [];
    final songMap = {for (final s in _songs) s.id: s};
    return pl.songIds.map((id) => songMap[id]).whereType<SongModel>().toList();
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playlistsKey, CustomPlaylist.encodeList(_playlists));
  }

  List<SongModel> getSongsByAlbum(int albumId) =>
      _songs.where((s) => s.albumId == albumId).toList();

  List<SongModel> getSongsByArtist(int artistId) =>
      _songs.where((s) => s.artistId == artistId).toList();
}
