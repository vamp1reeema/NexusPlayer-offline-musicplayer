import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:permission_handler/permission_handler.dart';

import 'equalizer.dart';

const bg = Color(0xFF100D0D);
const panel = Color(0xFF1C1517);
const panelSoft = Color(0xFF241A1C);
const line = Color(0xFF38292C);
const text = Color(0xFFEEE9E2);
const textDim = Color(0xFFB3A6A1);
const muted = Color(0xFF796B6B);
const blood = Color(0xFFA94443);
const bloodBright = Color(0xFFD15A55);
const silver = Color(0xFFCBC9C8);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.nexus_player.channel.audio',
    androidNotificationChannelName: 'Nexus Player',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
    fastForwardInterval: const Duration(seconds: 10),
    rewindInterval: const Duration(seconds: 10),
  );

  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  runApp(const NexusPlayerApp());
}

class NexusPlayerApp extends StatelessWidget {
  const NexusPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Nexus Player',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          surface: bg,
          primary: bloodBright,
          secondary: silver,
        ),
        fontFamily: 'sans',
        splashFactory: InkSparkle.splashFactory,
      ),
      home: const PlayerRoot(),
    );
  }
}

class DeviceTrack {
  const DeviceTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.uri,
    this.album,
    this.size = 0,
    this.dateAdded = 0,
  });

  final int id;
  final String title;
  final String artist;
  final Duration duration;
  final String uri;
  final String? album;
  final int size; // bytes
  final int dateAdded;
}

enum RepeatMode { off, one }

enum TrackSort { title, durationAsc, durationDesc, sizeAsc, sizeDesc, dateAdded }

class UserPlaylist {
  UserPlaylist({
    required this.id,
    required this.name,
    List<int>? trackIds,
    int? createdAt,
  })  : trackIds = trackIds ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  String name;
  final List<int> trackIds;
  final int createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'trackIds': trackIds,
        'createdAt': createdAt,
      };

  factory UserPlaylist.fromJson(Map<String, dynamic> json) => UserPlaylist(
        id: json['id'] as String,
        name: json['name'] as String,
        trackIds: List<int>.from(json['trackIds'] as List? ?? const []),
        createdAt: json['createdAt'] as int? ?? 0,
      );
}

class PlayerController extends ChangeNotifier {
  PlayerController() {
    _positionSubscription = _audioPlayer.positionStream.listen((position) {
      progress = position;
      notifyListeners();
    });
    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      isPlaying = state.playing;
      if (state.processingState == ProcessingState.completed) {
        _advanceAfterCompletion();
      }
      notifyListeners();
    });
    // Sync UI when user taps prev/next in the system notification
    _currentIndexSubscription = _audioPlayer.currentIndexStream.listen((index) {
      if (index == null) return;
      final list = queue.isNotEmpty ? queue : tracks;
      if (index < 0 || index >= list.length) return;
      final track = list[index];
      if (currentTrack?.id == track.id) return;
      currentTrack = track;
      progress = Duration.zero;
      _pushHistory(track.id);
      notifyListeners();
    });
    _loadPlaylists();
  }

  final OnAudioQuery _audioQuery = OnAudioQuery();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final Random _random = Random();

  List<DeviceTrack> tracks = const [];
  List<DeviceTrack> queue = const [];
  DeviceTrack? currentTrack;
  Duration progress = Duration.zero;
  bool isPlaying = false;
  bool isLoading = true;
  bool isScanning = false;
  bool permissionDenied = false;
  bool playerOpen = false;
  bool shuffle = false;
  RepeatMode repeatMode = RepeatMode.off;
  TrackSort sort = TrackSort.dateAdded;
  String? errorMessage;

  // Playlists
  List<UserPlaylist> playlists = [];
  Set<int> favoriteIds = {};
  List<int> historyIds = [];
  UserPlaylist? openPlaylist; // null = library, non-null = viewing a playlist

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<int?>? _currentIndexSubscription;

  List<DeviceTrack> tracksForIds(List<int> ids) {
    final byId = {for (final t in tracks) t.id: t};
    return ids.map((id) => byId[id]).whereType<DeviceTrack>().toList();
  }

  List<DeviceTrack> get favoriteTracks => tracksForIds(favoriteIds.toList());

  List<DeviceTrack> get historyTracks => tracksForIds(historyIds);

  Future<void> _loadPlaylists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('playlists_v1');
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        playlists = (data['playlists'] as List? ?? [])
            .map((e) => UserPlaylist.fromJson(e as Map<String, dynamic>))
            .toList();
        favoriteIds = Set<int>.from(data['favorites'] as List? ?? []);
        historyIds = List<int>.from(data['history'] as List? ?? []);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _savePlaylists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'playlists_v1',
        jsonEncode({
          'playlists': playlists.map((p) => p.toJson()).toList(),
          'favorites': favoriteIds.toList(),
          'history': historyIds,
        }),
      );
    } catch (_) {}
  }

  Future<void> createPlaylist(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    playlists = [
      ...playlists,
      UserPlaylist(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: trimmed,
      ),
    ];
    await _savePlaylists();
    notifyListeners();
  }

  Future<void> deletePlaylist(String id) async {
    playlists = playlists.where((p) => p.id != id).toList();
    if (openPlaylist?.id == id) openPlaylist = null;
    await _savePlaylists();
    notifyListeners();
  }

  Future<void> addTrackToPlaylist(String playlistId, int trackId) async {
    final idx = playlists.indexWhere((p) => p.id == playlistId);
    if (idx < 0) return;
    final p = playlists[idx];
    if (p.trackIds.contains(trackId)) return;
    p.trackIds.add(trackId);
    playlists = List.from(playlists);
    await _savePlaylists();
    notifyListeners();
  }

  Future<void> removeTrackFromPlaylist(String playlistId, int trackId) async {
    final idx = playlists.indexWhere((p) => p.id == playlistId);
    if (idx < 0) return;
    playlists[idx].trackIds.remove(trackId);
    playlists = List.from(playlists);
    await _savePlaylists();
    notifyListeners();
  }

  /// Tries to delete the audio file from device storage and removes it from lists.
  Future<bool> deleteTrackFromDevice(DeviceTrack track) async {
    var deleted = false;
    try {
      // content:// or file:// — try path first
      final raw = track.uri;
      String? path;
      if (raw.startsWith('file://')) {
        path = Uri.parse(raw).toFilePath();
      } else if (raw.startsWith('/')) {
        path = raw;
      }
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          deleted = true;
        }
      }
    } catch (_) {
      deleted = false;
    }

    // Always remove from in-memory library so UI updates
    tracks = tracks.where((t) => t.id != track.id).toList();
    queue = queue.where((t) => t.id != track.id).toList();
    favoriteIds.remove(track.id);
    historyIds.remove(track.id);
    for (final p in playlists) {
      p.trackIds.remove(track.id);
    }
    if (currentTrack?.id == track.id) {
      await _audioPlayer.stop();
      currentTrack = null;
      isPlaying = false;
      playerOpen = false;
      progress = Duration.zero;
    }
    await _savePlaylists();
    notifyListeners();
    return deleted;
  }

  Future<void> toggleFavorite(int trackId) async {
    if (favoriteIds.contains(trackId)) {
      favoriteIds.remove(trackId);
    } else {
      favoriteIds.add(trackId);
    }
    favoriteIds = Set.from(favoriteIds);
    await _savePlaylists();
    notifyListeners();
  }

  bool isFavorite(int trackId) => favoriteIds.contains(trackId);

  void _pushHistory(int trackId) {
    historyIds.remove(trackId);
    historyIds.insert(0, trackId);
    if (historyIds.length > 100) {
      historyIds = historyIds.sublist(0, 100);
    }
    _savePlaylists();
  }

  void openPlaylistView(UserPlaylist? playlist) {
    openPlaylist = playlist;
    notifyListeners();
  }

  void closePlaylistView() {
    openPlaylist = null;
    notifyListeners();
  }

  Future<void> scanDevice() async {
    isScanning = true;
    isLoading = true;
    permissionDenied = false;
    errorMessage = null;
    notifyListeners();

    try {
      if (!Platform.isAndroid && !Platform.isIOS) {
        tracks = const [];
        errorMessage = 'Сканирование медиатеки доступно на телефоне.';
      } else {
        final allowed = await _audioQuery.permissionsRequest();
        if (!allowed) {
          permissionDenied = true;
          tracks = const [];
        } else {
          final songs = await _audioQuery.querySongs(
            sortType: SongSortType.TITLE,
            orderType: OrderType.ASC_OR_SMALLER,
            uriType: UriType.EXTERNAL,
            ignoreCase: true,
          );

          tracks = songs
              .where((song) {
                final duration = song.duration ?? 0;
                final uri = song.uri ?? song.data;
                return duration >= 10000 && uri.isNotEmpty;
              })
              .map(
                (song) => DeviceTrack(
                  id: song.id,
                  title: _cleanTitle(song.title),
                  artist: _cleanArtist(song.artist),
                  duration: Duration(milliseconds: song.duration ?? 0),
                  uri: song.uri ?? song.data,
                  album: song.album,
                  size: song.size ?? 0,
                  dateAdded: song.dateAdded ?? 0,
                ),
              )
              .toList();
          _applySort();
        }
      }
    } catch (_) {
      errorMessage = 'Не удалось прочитать медиатеку устройства.';
    } finally {
      isScanning = false;
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectTrack(
    DeviceTrack track, {
    List<DeviceTrack>? fromQueue,
  }) async {
    if (fromQueue != null && fromQueue.isNotEmpty) {
      queue = List.from(fromQueue);
    } else if (queue.isEmpty) {
      queue = List.from(tracks);
    }
    currentTrack = track;
    progress = Duration.zero;
    playerOpen = true;
    errorMessage = null;
    _pushHistory(track.id);
    notifyListeners();

    try {
      final list = queue.isNotEmpty ? queue : tracks;
      var initialIndex = list.indexWhere((t) => t.id == track.id);
      if (initialIndex < 0) initialIndex = 0;

      // Full queue → system notification gets prev / next buttons
      // just_audio 0.9.x: use ConcatenatingAudioSource (no setAudioSources yet)
      await _audioPlayer.setAudioSource(
        ConcatenatingAudioSource(
          children: list
              .map(
                (t) => AudioSource.uri(
                  Uri.parse(t.uri),
                  tag: MediaItem(
                    id: t.id.toString(),
                    title: t.title,
                    artist: t.artist,
                    duration: t.duration,
                    album: t.album,
                  ),
                ),
              )
              .toList(),
        ),
        initialIndex: initialIndex,
        initialPosition: Duration.zero,
      );
      await _audioPlayer.setShuffleModeEnabled(shuffle);
      await _audioPlayer.setLoopMode(
        repeatMode == RepeatMode.one ? LoopMode.one : LoopMode.off,
      );
      await _audioPlayer.play();
      // Attach system equalizer to this audio session (global for all tracks)
      final sessionId = _audioPlayer.androidAudioSessionId;
      if (sessionId != null) {
        await EqualizerEngine.attach(sessionId);
      }
    } catch (_) {
      errorMessage = 'Этот файл не удалось открыть.';
      isPlaying = false;
      notifyListeners();
    }
  }

  Future<void> playAll(List<DeviceTrack> list) async {
    if (list.isEmpty) return;
    await selectTrack(list.first, fromQueue: list);
  }

  Future<void> togglePlayback() async {
    if (currentTrack == null) return;
    if (isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  Future<void> seek(Duration position) => _audioPlayer.seek(position);

  Future<void> previous() async {
    if (progress > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    if (_audioPlayer.hasPrevious) {
      await _audioPlayer.seekToPrevious();
      return;
    }
    final list = queue.isNotEmpty ? queue : tracks;
    if (list.isEmpty || currentTrack == null) return;
    final index = list.indexWhere((t) => t.id == currentTrack!.id);
    final previousIndex = index <= 0 ? list.length - 1 : index - 1;
    await selectTrack(list[previousIndex], fromQueue: list);
  }

  Future<void> next() async {
    if (_audioPlayer.hasNext) {
      await _audioPlayer.seekToNext();
      return;
    }
    final list = queue.isNotEmpty ? queue : tracks;
    if (list.isEmpty || currentTrack == null) return;
    await _playNext();
  }

  void backToLibrary() {
    playerOpen = false;
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    shuffle = !shuffle;
    await _audioPlayer.setShuffleModeEnabled(shuffle);
    notifyListeners();
  }

  Future<void> toggleRepeat() async {
    repeatMode =
        repeatMode == RepeatMode.off ? RepeatMode.one : RepeatMode.off;
    await _audioPlayer.setLoopMode(
      repeatMode == RepeatMode.one ? LoopMode.one : LoopMode.off,
    );
    notifyListeners();
  }

  void setSort(TrackSort value) {
    sort = value;
    _applySort();
    notifyListeners();
  }

  void _applySort() {
    final list = List<DeviceTrack>.from(tracks);
    list.sort((a, b) {
      switch (sort) {
        case TrackSort.title:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case TrackSort.durationAsc:
          return a.duration.compareTo(b.duration);
        case TrackSort.durationDesc:
          return b.duration.compareTo(a.duration);
        case TrackSort.sizeAsc:
          return a.size.compareTo(b.size);
        case TrackSort.sizeDesc:
          return b.size.compareTo(a.size);
        case TrackSort.dateAdded:
          return b.dateAdded.compareTo(a.dateAdded);
      }
    });
    tracks = list;
  }

  Future<void> _advanceAfterCompletion() async {
    if (repeatMode == RepeatMode.one) {
      await _audioPlayer.seek(Duration.zero);
      await _audioPlayer.play();
      return;
    }
    await _playNext();
  }

  Future<void> _playNext() async {
    final list = queue.isNotEmpty ? queue : tracks;
    if (list.isEmpty || currentTrack == null) return;
    final currentIndex = list.indexWhere((t) => t.id == currentTrack!.id);
    var nextIndex = currentIndex + 1;
    if (shuffle && list.length > 1) {
      do {
        nextIndex = _random.nextInt(list.length);
      } while (nextIndex == currentIndex);
    } else if (nextIndex >= list.length) {
      nextIndex = 0;
    }
    await selectTrack(list[nextIndex], fromQueue: list);
  }

  static String _cleanTitle(String value) {
    if (value.trim().isEmpty || value == '<unknown>') return 'Без названия';
    return value.trim();
  }

  static String _cleanArtist(String? value) {
    if (value == null || value.trim().isEmpty || value == '<unknown>') {
      return 'Неизвестный исполнитель';
    }
    return value.trim();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _currentIndexSubscription?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }
}

class PlayerRoot extends StatefulWidget {
  const PlayerRoot({super.key});

  @override
  State<PlayerRoot> createState() => _PlayerRootState();
}

class _PlayerRootState extends State<PlayerRoot> {
  late final PlayerController controller;

  @override
  void initState() {
    super.initState();
    controller = PlayerController()..scanDevice();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final showPlayer =
            controller.playerOpen && controller.currentTrack != null;
        final showPlaylist = controller.openPlaylist != null;

        return PopScope(
          canPop: !showPlayer && !showPlaylist,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (showPlayer) {
              controller.backToLibrary();
            } else if (showPlaylist) {
              controller.closePlaylistView();
            }
          },
          // Keep LibraryScreen mounted so scroll position is preserved
          child: Stack(
            children: [
              TickerMode(
                enabled: !showPlayer,
                child: Offstage(
                  offstage: showPlayer,
                  child: LibraryScreen(controller: controller),
                ),
              ),
              IgnorePointer(
                ignoring: !showPlayer,
                child: AnimatedOpacity(
                  opacity: showPlayer ? 1 : 0,
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  child: showPlayer
                      ? PlayerScreen(controller: controller)
                      : const SizedBox.expand(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({required this.controller, super.key});

  final PlayerController controller;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int tab = 1; // 0 = playlists, 1 = tracks
  String query = '';

  void _showSortMenu() {
    final controller = widget.controller;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        Widget item(String label, TrackSort value) {
          final selected = controller.sort == value;
          return ListTile(
            title: Text(
              label,
              style: TextStyle(
                color: selected ? bloodBright : text,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            trailing: selected
                ? const Icon(Icons.check, color: bloodBright, size: 18)
                : null,
            onTap: () {
              controller.setSort(value);
              Navigator.pop(context);
            },
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Сортировка',
                    style: TextStyle(
                      color: text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              item('По названию', TrackSort.title),
              item('По длительности ↑ (короче)', TrackSort.durationAsc),
              item('По длительности ↓ (длиннее)', TrackSort.durationDesc),
              item('По размеру ↑ (меньше)', TrackSort.sizeAsc),
              item('По размеру ↓ (больше)', TrackSort.sizeDesc),
              item('По дате добавления', TrackSort.dateAdded),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showCreatePlaylistDialog() async {
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: panel,
        title: const Text('Создать плейлист', style: TextStyle(color: text)),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: const TextStyle(color: text),
          decoration: const InputDecoration(
            hintText: 'Название плейлиста',
            hintStyle: TextStyle(color: muted),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: line),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: bloodBright),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отменить', style: TextStyle(color: muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('OK', style: TextStyle(color: bloodBright)),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      await widget.controller.createPlaylist(result);
    }
  }

  Future<void> _showTrackMenu(DeviceTrack track) async {
    final controller = widget.controller;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: text,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  controller.isFavorite(track.id)
                      ? Icons.favorite
                      : Icons.favorite_border,
                  color: bloodBright,
                ),
                title: Text(
                  controller.isFavorite(track.id)
                      ? 'Убрать из избранного'
                      : 'В избранное',
                  style: const TextStyle(color: text),
                ),
                onTap: () {
                  controller.toggleFavorite(track.id);
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add, color: textDim),
                title: const Text(
                  'Добавить в плейлист',
                  style: TextStyle(color: text),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAddToPlaylist(track);
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline, color: textDim),
                title: const Text(
                  'Информация',
                  style: TextStyle(color: text),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showTrackInfo(track);
                },
              ),
              ListTile(
                leading: const Icon(Icons.graphic_eq_rounded, color: textDim),
                title: const Text(
                  'Эквалайзер',
                  style: TextStyle(color: text),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EqualizerScreen(),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: bloodBright),
                title: const Text(
                  'Удалить с устройства',
                  style: TextStyle(color: bloodBright),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteTrack(track);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAddToPlaylist(DeviceTrack track) async {
    final controller = widget.controller;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Добавить в плейлист',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.favorite_border, color: bloodBright),
                title: Text(
                  controller.isFavorite(track.id)
                      ? 'Убрать из избранного'
                      : 'В избранное',
                  style: const TextStyle(color: text),
                ),
                onTap: () {
                  controller.toggleFavorite(track.id);
                  Navigator.pop(context);
                },
              ),
              if (controller.playlists.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'Нет плейлистов. Создай новый во вкладке «Плейлисты».',
                    style: TextStyle(color: muted, fontSize: 13),
                  ),
                )
              else
                ...controller.playlists.map((p) {
                  final added = p.trackIds.contains(track.id);
                  return ListTile(
                    leading: Icon(
                      added ? Icons.check_circle : Icons.playlist_add,
                      color: added ? bloodBright : textDim,
                    ),
                    title: Text(p.name, style: const TextStyle(color: text)),
                    subtitle: Text(
                      '${p.trackIds.length} треков',
                      style: const TextStyle(color: muted, fontSize: 11),
                    ),
                    onTap: () async {
                      if (added) {
                        await controller.removeTrackFromPlaylist(p.id, track.id);
                      } else {
                        await controller.addTrackToPlaylist(p.id, track.id);
                      }
                      if (context.mounted) Navigator.pop(context);
                    },
                  );
                }),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showTrackInfo(DeviceTrack track) async {
    String formatSize(int bytes) {
      if (bytes <= 0) return '—';
      if (bytes < 1024) return '$bytes B';
      if (bytes < 1024 * 1024) {
        return '${(bytes / 1024).toStringAsFixed(1)} KB';
      }
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }

    final path = track.uri;
    final fileName = path.split('/').last.split('?').first;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        Widget chip(String title, String value) {
          return Expanded(
            child: Container(
              margin: const EdgeInsets.all(4),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              decoration: BoxDecoration(
                color: panelSoft,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: line),
              ),
              child: Column(
                children: [
                  Text(
                    value,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: text,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted, fontSize: 10),
                  ),
                ],
              ),
            ),
          );
        }

        Widget row(String label, String value) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: muted, fontSize: 11)),
                const SizedBox(height: 4),
                Text(
                  value.isEmpty ? '—' : value,
                  style: const TextStyle(color: text, fontSize: 14),
                ),
              ],
            ),
          );
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    chip('Формат', fileName.toLowerCase().endsWith('.flac')
                        ? 'FLAC'
                        : fileName.toLowerCase().endsWith('.wav')
                            ? 'WAV'
                            : fileName.toLowerCase().endsWith('.m4a')
                                ? 'M4A'
                                : 'MPEG'),
                    chip('Длительность', formatDuration(track.duration)),
                    chip('Размер', formatSize(track.size)),
                    chip('Каналы', '2 ch'),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'ФАЙЛ',
                  style: TextStyle(
                    color: muted,
                    fontSize: 11,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: panelSoft,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      row('Название файла', fileName),
                      const Divider(color: line, height: 1),
                      row('Расположение', path),
                      const Divider(color: line, height: 1),
                      Row(
                        children: [
                          Expanded(child: row('Размер', formatSize(track.size))),
                          Expanded(
                            child: row(
                              'Длительность',
                              formatDuration(track.duration),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'ТЕГИ',
                  style: TextStyle(
                    color: muted,
                    fontSize: 11,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: panelSoft,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      row('Название', track.title),
                      const Divider(color: line, height: 1),
                      row('Исполнитель', track.artist),
                      const Divider(color: line, height: 1),
                      row('Альбом', track.album ?? '—'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmDeleteTrack(DeviceTrack track) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        title: const Text('Удалить трек?', style: TextStyle(color: text)),
        content: Text(
          'Файл «${track.title}» будет удалён с устройства. Это действие нельзя отменить.',
          style: const TextStyle(color: textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена', style: TextStyle(color: muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Удалить',
              style: TextStyle(color: bloodBright),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      final result = await widget.controller.deleteTrackFromDevice(track);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result
                ? 'Трек удалён с устройства'
                : 'Не удалось удалить файл. Нужно разрешение на доступ.',
          ),
          backgroundColor: panelSoft,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    if (controller.openPlaylist != null) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final offset = Tween<Offset>(
            begin: const Offset(0.06, 0),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: offset, child: child),
          );
        },
        child: KeyedSubtree(
          key: ValueKey('pl_${controller.openPlaylist!.id}'),
          child: _PlaylistDetailScreen(
            controller: controller,
            playlist: controller.openPlaylist!,
            onAddToPlaylist: _showTrackMenu,
          ),
        ),
      );
    }

    final visibleTracks = controller.tracks.where((track) {
      final value = '${track.title} ${track.artist}'.toLowerCase();
      return value.contains(query.toLowerCase());
    }).toList();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _LibraryHeader(onScan: controller.scanDevice),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final offset = Tween<Offset>(
                    begin: const Offset(0.03, 0),
                    end: Offset.zero,
                  ).animate(animation);
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(position: offset, child: child),
                  );
                },
                child: tab == 0
                    ? KeyedSubtree(
                        key: const ValueKey('tab_playlists'),
                        child: _PlaylistsTab(
                          controller: controller,
                          onCreate: _showCreatePlaylistDialog,
                        ),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('tab_tracks'),
                        child: RefreshIndicator(
                      color: bloodBright,
                      backgroundColor: panel,
                      onRefresh: controller.scanDevice,
                      child: CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(20, 34, 20, 0),
                            sliver: SliverToBoxAdapter(
                              child: _LibraryIntro(
                                isPlaylist: false,
                                query: query,
                                onQueryChanged: (value) =>
                                    setState(() => query = value),
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(20, 42, 20, 0),
                            sliver: SliverToBoxAdapter(
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  const Text(
                                    'Список треков',
                                    style: TextStyle(
                                      color: text,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Row(
                                    children: [
                                      Text(
                                        '${visibleTracks.length}',
                                        style: const TextStyle(
                                          color: muted,
                                          fontSize: 11,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      GestureDetector(
                                        onTap: _showSortMenu,
                                        child: const Icon(
                                          Icons.sort_rounded,
                                          color: textDim,
                                          size: 22,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (controller.isLoading)
                            const SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: bloodBright,
                                ),
                              ),
                            )
                          else if (controller.permissionDenied)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: _EmptyLibrary(
                                title: 'Нужен доступ к музыке',
                                message:
                                    'Разрешите доступ к аудиофайлам, чтобы показать все треки, скачанные на телефон.',
                                action: 'Повторить сканирование',
                                onPressed: controller.scanDevice,
                              ),
                            )
                          else if (controller.tracks.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: _EmptyLibrary(
                                title: 'Треки не найдены',
                                message:
                                    'Список строится из медиатеки устройства. Файлы короче 10 секунд автоматически скрываются.',
                                action: 'Сканировать устройство',
                                onPressed: controller.scanDevice,
                              ),
                            )
                          else if (visibleTracks.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: _EmptyLibrary(
                                title: 'Ничего не найдено',
                                message:
                                    'Попробуйте изменить поисковый запрос.',
                                action: 'Очистить поиск',
                                onPressed: () async =>
                                    setState(() => query = ''),
                              ),
                            )
                          else
                            SliverPadding(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 14, 20, 126),
                              sliver: SliverList.separated(
                                itemCount: visibleTracks.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(color: line, height: 1),
                                itemBuilder: (context, index) {
                                  final track = visibleTracks[index];
                                  final current =
                                      controller.currentTrack?.id == track.id;
                                  return TrackTile(
                                    index: index + 1,
                                    track: track,
                                    current: current,
                                    playing: current && controller.isPlaying,
                                    onTap: () => controller.selectTrack(
                                      track,
                                      fromQueue: visibleTracks,
                                    ),
                                    onMore: () => _showTrackMenu(track),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                      ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomBar(
        selectedIndex: tab,
        onChanged: (value) => setState(() => tab = value),
        currentTrack: controller.currentTrack,
        isPlaying: controller.isPlaying,
        onMiniPlayerTap: controller.currentTrack == null
            ? null
            : () => setState(() => controller.playerOpen = true),
        onTogglePlayback: controller.currentTrack == null
            ? null
            : controller.togglePlayback,
      ),
    );
  }
}

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader({required this.onScan});

  final Future<void> Function() onScan;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      child: Row(
        children: [
          Transform.rotate(
            angle: pi / 4,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(border: Border.all(color: blood)),
              child: Transform.rotate(
                angle: -pi / 4,
                child: const Center(
                  child: Text(
                    'NP',
                    style: TextStyle(
                      color: bloodBright,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 13),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'NEXUS PLAYER',
                  style: TextStyle(
                    color: text,
                    fontSize: 12,
                    letterSpacing: 2.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 5),
                Text(
                  'OFFLINE PLAYER / DEVICE LIBRARY',
                  style: TextStyle(color: muted, fontSize: 8, letterSpacing: 1),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onScan,
            tooltip: 'Обновить медиатеку',
            icon: const Icon(Icons.sync_rounded, color: textDim, size: 20),
          ),
        ],
      ),
    );
  }
}

class _LibraryIntro extends StatelessWidget {
  const _LibraryIntro({
    required this.isPlaylist,
    required this.query,
    required this.onQueryChanged,
  });

  final bool isPlaylist;
  final String query;
  final ValueChanged<String> onQueryChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'ЛИЧНАЯ КОЛЛЕКЦИЯ / УСТРОЙСТВО',
          style: TextStyle(color: bloodBright, fontSize: 10, letterSpacing: 2),
        ),
        const SizedBox(height: 14),
        Text(
          isPlaylist ? 'Ваша тёмная\nкомната' : 'Все\nтреки',
          style: const TextStyle(
            color: text,
            fontSize: 38,
            height: .98,
            letterSpacing: -1.8,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Музыка с устройства, доступная офлайн. Нажмите на трек — проигрывание начнётся сразу.',
          style: TextStyle(color: muted, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 22),
        TextField(
          onChanged: onQueryChanged,
          style: const TextStyle(color: text, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Найти в медиатеке',
            hintStyle: const TextStyle(color: muted, fontSize: 13),
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: muted,
              size: 19,
            ),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    onPressed: () => onQueryChanged(''),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: muted,
                      size: 18,
                    ),
                  ),
            filled: true,
            fillColor: panel,
            contentPadding: const EdgeInsets.symmetric(
              vertical: 14,
              horizontal: 4,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: blood),
            ),
          ),
        ),
      ],
    );
  }
}

class TrackTile extends StatelessWidget {
  const TrackTile({
    required this.index,
    required this.track,
    required this.current,
    required this.playing,
    required this.onTap,
    this.onMore,
    super.key,
  });

  final int index;
  final DeviceTrack track;
  final bool current;
  final bool playing;
  final VoidCallback onTap;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onMore,
      splashColor: blood.withValues(alpha: .16),
      highlightColor: blood.withValues(alpha: .08),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: playing
                  ? const _Equalizer()
                  : Text(
                      index.toString().padLeft(2, '0'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: current ? bloodBright : muted,
                        fontSize: 10,
                      ),
                    ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: current ? text : textDim,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              formatDuration(track.duration),
              style: const TextStyle(color: muted, fontSize: 10),
            ),
            if (onMore != null) ...[
              const SizedBox(width: 4),
              IconButton(
                onPressed: onMore,
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: current ? bloodBright : muted,
                  size: 18,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ] else ...[
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right_rounded,
                color: current ? bloodBright : muted,
                size: 18,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Equalizer extends StatefulWidget {
  const _Equalizer();

  @override
  State<_Equalizer> createState() => _EqualizerState();
}

class _EqualizerState extends State<_Equalizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController animationController;

  @override
  void initState() {
    super.initState();
    animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animationController,
      builder: (_, __) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _bar(.45 + animationController.value * .25),
          const SizedBox(width: 3),
          _bar(.7 + animationController.value * .3),
          const SizedBox(width: 3),
          _bar(.5 + animationController.value * .3),
        ],
      ),
    );
  }

  Widget _bar(double height) => Container(
    width: 2,
    height: 14 * height,
    decoration: BoxDecoration(
      color: bloodBright,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.selectedIndex,
    required this.onChanged,
    required this.currentTrack,
    required this.isPlaying,
    required this.onMiniPlayerTap,
    required this.onTogglePlayback,
  });

  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final DeviceTrack? currentTrack;
  final bool isPlaying;
  final VoidCallback? onMiniPlayerTap;
  final Future<void> Function()? onTogglePlayback;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: panel,
          border: Border(top: BorderSide(color: line)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (currentTrack != null)
              InkWell(
                onTap: onMiniPlayerTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 10, 10, 10),
                  child: Row(
                    children: [
                      const VinylThumbnail(),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              currentTrack!.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: text, fontSize: 12),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              isPlaying ? 'Воспроизводится сейчас' : 'На паузе',
                              style: const TextStyle(color: muted, fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: onTogglePlayback,
                        icon: Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: text,
                          size: 21,
                        ),
                        style: IconButton.styleFrom(backgroundColor: blood),
                      ),
                    ],
                  ),
                ),
              ),
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  _navItem(Icons.queue_music_rounded, 'Треки', 1),
                  _navItem(Icons.playlist_play_rounded, 'Плейлисты', 0),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int index) {
    final selected = selectedIndex == index;
    return Expanded(
      child: InkWell(
        onTap: () => onChanged(index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: selected ? bloodBright : muted),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? bloodBright : muted,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _PlaylistsTab extends StatelessWidget {
  const _PlaylistsTab({required this.controller, required this.onCreate});

  final PlayerController controller;
  final Future<void> Function() onCreate;

  @override
  Widget build(BuildContext context) {
    final favorites = controller.favoriteTracks;
    final history = controller.historyTracks;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
      children: [
        const Text(
          'Плейлисты',
          style: TextStyle(
            color: text,
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _PlaylistCard(
                icon: Icons.favorite_rounded,
                title: 'Избранное',
                subtitle: '${favorites.length} треков',
                onTap: () {
                  controller.openPlaylistView(
                    UserPlaylist(
                      id: '__favorites__',
                      name: 'Избранное',
                      trackIds: controller.favoriteIds.toList(),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PlaylistCard(
                icon: Icons.history_rounded,
                title: 'История',
                subtitle: '${history.length} треков',
                onTap: () {
                  controller.openPlaylistView(
                    UserPlaylist(
                      id: '__history__',
                      name: 'История',
                      trackIds: List.from(controller.historyIds),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Мои плейлисты',
              style: TextStyle(
                color: text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            IconButton(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded, color: bloodBright),
              tooltip: 'Создать плейлист',
            ),
          ],
        ),
        if (controller.playlists.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                'Нажми + чтобы создать плейлист',
                style: TextStyle(color: muted, fontSize: 13),
              ),
            ),
          )
        else
          ...controller.playlists.map((p) {
            final count = controller.tracksForIds(p.trackIds).length;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: panelSoft,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: line),
                ),
                child: const Icon(Icons.music_note, color: muted),
              ),
              title: Text(p.name, style: const TextStyle(color: text)),
              subtitle: Text(
                '$count треков',
                style: const TextStyle(color: muted, fontSize: 11),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: muted, size: 20),
                onPressed: () => controller.deletePlaylist(p.id),
              ),
              onTap: () => controller.openPlaylistView(p),
            );
          }),
      ],
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: panelSoft,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: bloodBright, size: 22),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: text,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: muted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _PlaylistDetailScreen extends StatelessWidget {
  const _PlaylistDetailScreen({
    required this.controller,
    required this.playlist,
    required this.onAddToPlaylist,
  });

  final PlayerController controller;
  final UserPlaylist playlist;
  final Future<void> Function(DeviceTrack) onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final List<int> ids;
    if (playlist.id == '__favorites__') {
      ids = controller.favoriteIds.toList();
    } else if (playlist.id == '__history__') {
      ids = List.from(controller.historyIds);
    } else {
      final live = controller.playlists
          .where((p) => p.id == playlist.id)
          .firstOrNull;
      ids = live?.trackIds ?? playlist.trackIds;
    }
    final tracks = controller.tracksForIds(ids);
    final totalDuration = tracks.fold<Duration>(
      Duration.zero,
      (sum, t) => sum + t.duration,
    );

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: controller.closePlaylistView,
                    icon: const Icon(Icons.arrow_back_rounded, color: text),
                  ),
                  Expanded(
                    child: Text(
                      playlist.name,
                      style: const TextStyle(
                        color: text,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${tracks.length} треков · ${formatDuration(totalDuration)}',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  if (tracks.isNotEmpty)
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => controller.playAll(tracks),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: silver,
                              foregroundColor: bg,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                            ),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Воспроизвести все'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          onPressed: () {
                            controller.toggleShuffle();
                            controller.playAll(tracks);
                          },
                          style: IconButton.styleFrom(
                            backgroundColor: panelSoft,
                          ),
                          icon: Icon(
                            Icons.shuffle_rounded,
                            color: controller.shuffle ? bloodBright : textDim,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            Expanded(
              child: tracks.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(28),
                        child: Text(
                          'Плейлист пуст\n\nДолгое нажатие на трек в списке → «Добавить в плейлист»',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: muted, fontSize: 13),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
                      itemCount: tracks.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: line, height: 1),
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        final current =
                            controller.currentTrack?.id == track.id;
                        return TrackTile(
                          index: index + 1,
                          track: track,
                          current: current,
                          playing: current && controller.isPlaying,
                          onTap: () => controller.selectTrack(
                            track,
                            fromQueue: tracks,
                          ),
                          onMore: () => onAddToPlaylist(track),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomBar(
        selectedIndex: 0,
        onChanged: (_) => controller.closePlaylistView(),
        currentTrack: controller.currentTrack,
        isPlaying: controller.isPlaying,
        onMiniPlayerTap: controller.currentTrack == null
            ? null
            : () {
                controller.playerOpen = true;
                controller.notifyListeners();
              },
        onTogglePlayback: controller.currentTrack == null
            ? null
            : controller.togglePlayback,
      ),
    );
  }
}

class VinylThumbnail extends StatelessWidget {
  const VinylThumbnail({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: line),
      ),
      child: const VinylDisc(),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({
    required this.title,
    required this.message,
    required this.action,
    required this.onPressed,
  });

  final String title;
  final String message;
  final String action;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.album_outlined, color: muted, size: 42),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: text,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: bloodBright,
                side: const BorderSide(color: blood),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
              ),
              child: Text(action),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({required this.controller, super.key});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final track = controller.currentTrack!;
    final duration = track.duration;
    final progress = controller.progress.inMilliseconds.clamp(
      0,
      duration.inMilliseconds,
    );
    final ratio = duration.inMilliseconds == 0
        ? 0.0
        : progress / duration.inMilliseconds;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: controller.backToLibrary,
                    icon: const Icon(Icons.arrow_back_rounded, size: 19),
                    label: const Text('Коллекция'),
                    style: TextButton.styleFrom(
                      foregroundColor: textDim,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                  const Text(
                    'СЕЙЧАС ИГРАЕТ',
                    style: TextStyle(
                      color: muted,
                      fontSize: 9,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      flex: 7,
                      child: Center(
                        child: VinylStage(isPlaying: controller.isPlaying),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      track.title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: text,
                        fontSize: 27,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -.8,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      track.artist,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                    const SizedBox(height: 30),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _PlayerButton(
                          icon: Icons.repeat_rounded,
                          active: controller.repeatMode == RepeatMode.one,
                          onPressed: controller.toggleRepeat,
                          tooltip: 'Повтор',
                        ),
                        const SizedBox(width: 16),
                        _PlayerButton(
                          icon: Icons.skip_previous_rounded,
                          onPressed: controller.previous,
                          tooltip: 'Предыдущий',
                        ),
                        const SizedBox(width: 16),
                        _PlayButton(
                          playing: controller.isPlaying,
                          onPressed: controller.togglePlayback,
                        ),
                        const SizedBox(width: 16),
                        _PlayerButton(
                          icon: Icons.skip_next_rounded,
                          onPressed: controller.next,
                          tooltip: 'Следующий',
                        ),
                        const SizedBox(width: 16),
                        _PlayerButton(
                          icon: Icons.shuffle_rounded,
                          active: controller.shuffle,
                          onPressed: controller.toggleShuffle,
                          tooltip: 'Случайный порядок',
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: blood,
                        inactiveTrackColor: const Color(0xFF403637),
                        thumbColor: silver,
                        overlayColor: blood.withValues(alpha: .15),
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                      ),
                      child: Slider(
                        value: ratio.clamp(0.0, 1.0),
                        onChanged: (value) => controller.seek(
                          Duration(
                            milliseconds: (duration.inMilliseconds * value)
                                .round(),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          formatDuration(Duration(milliseconds: progress)),
                          style: const TextStyle(color: muted, fontSize: 10),
                        ),
                        Text(
                          formatDuration(duration),
                          style: const TextStyle(color: muted, fontSize: 10),
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    Text(
                      'OFFLINE  •  ${track.album ?? 'УСТРОЙСТВО'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: muted,
                        fontSize: 9,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerButton extends StatelessWidget {
  const _PlayerButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, color: active ? bloodBright : blood, size: 23),
      style: IconButton.styleFrom(
        backgroundColor: active
            ? blood.withValues(alpha: .14)
            : Colors.transparent,
        shape: const CircleBorder(),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.onPressed});

  final bool playing;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(
        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        color: const Color(0xFF1B1617),
        size: 31,
      ),
      style: IconButton.styleFrom(
        backgroundColor: silver,
        fixedSize: const Size(72, 72),
        shape: const CircleBorder(),
      ),
    );
  }
}

class VinylStage extends StatefulWidget {
  const VinylStage({required this.isPlaying, super.key});

  final bool isPlaying;

  @override
  State<VinylStage> createState() => _VinylStageState();
}

/// Vinyl spins continuously while playing and *reacts to real audio energy*
/// from the Android Visualizer (not a random timer).
class _VinylStageState extends State<VinylStage>
    with TickerProviderStateMixin {
  late final AnimationController _spinController;
  StreamSubscription<double>? _vizSub;
  bool _wasPlaying = false;

  /// Smoothed energy 0..1 from Visualizer
  double _energy = 0.0;
  /// Previous energy for beat-onset detection
  double _prevEnergy = 0.0;
  /// Short kick envelope 0..1 (decays each frame)
  double _kick = 0.0;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    );
    if (widget.isPlaying) {
      _spinController.repeat();
      _startViz();
    }
    _wasPlaying = widget.isPlaying;
  }

  Future<void> _startViz() async {
    // Visualizer needs mic permission on many OEMs
    try {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        // Still try — some devices allow session-only capture
      }
    } catch (_) {}
    await _vizSub?.cancel();
    _vizSub = AudioVisualizer.stream.listen((e) {
      if (!mounted || !widget.isPlaying) return;
      // Beat onset: energy jumps above a threshold relative to recent level
      final rise = e - _prevEnergy;
      if (e > 0.18 && rise > 0.045) {
        // Stronger beats → stronger kick
        final strength = ((e - 0.1) / 0.7).clamp(0.25, 1.0);
        if (strength > _kick) _kick = strength;
      }
      _prevEnergy = e;
      _energy = e;
      // Decay kick quickly so each hit is punchy
      _kick = (_kick * 0.82).clamp(0.0, 1.0);
      setState(() {});
    });
  }

  void _stopViz() {
    _vizSub?.cancel();
    _vizSub = null;
    _energy = 0;
    _prevEnergy = 0;
    _kick = 0;
  }

  @override
  void didUpdateWidget(covariant VinylStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying == _wasPlaying) return;
    _wasPlaying = widget.isPlaying;
    if (widget.isPlaying) {
      _spinController.repeat();
      _startViz();
    } else {
      _spinController.stop();
      _stopViz();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _stopViz();
    _spinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = min(constraints.maxWidth, constraints.maxHeight);
        // Continuous low bob from energy + sharp kick on beat onsets
        final scale = 1.0 + (_energy * 0.04) + (_kick * 0.07);
        final wobble = _kick * 0.05;

        return Container(
          width: size,
          height: size,
          padding: EdgeInsets.all(size * .08),
          decoration: BoxDecoration(
            color: const Color(0xFF0B090A),
            border: Border.all(color: const Color(0x1ACBC9C8)),
          ),
          child: AnimatedBuilder(
            animation: _spinController,
            builder: (_, child) {
              return Transform.scale(
                scale: scale,
                child: Transform.rotate(
                  angle: _spinController.value * pi * 2 + wobble,
                  child: child,
                ),
              );
            },
            child: const VinylDisc(),
          ),
        );
      },
    );
  }
}

class VinylDisc extends StatelessWidget {
  const VinylDisc({super.key});

  @override
  Widget build(BuildContext context) {
    return const CustomPaint(painter: VinylPainter());
  }
}

/// Vinyl with asymmetric highlights so rotation is clearly visible
class VinylPainter extends CustomPainter {
  const VinylPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2;

    // Base disc
    final discPaint = Paint()
      ..shader = RadialGradient(
        colors: const [
          Color(0xFF2E2E2E),
          Color(0xFF141414),
          Color(0xFF070707),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, discPaint);

    // Grooves — alternating brightness rings
    final groovePaint = Paint()..style = PaintingStyle.stroke;
    for (var i = 0; i < 36; i++) {
      final t = 0.24 + (i / 36) * 0.70;
      groovePaint.strokeWidth = i % 3 == 0 ? 1.1 : 0.55;
      groovePaint.color = Color.fromRGBO(
        255,
        255,
        255,
        i % 3 == 0 ? 0.16 : (i.isEven ? 0.09 : 0.04),
      );
      canvas.drawCircle(center, radius * t, groovePaint);
    }

    // Asymmetric specular wedge (rotates with disc → visible spin)
    final highlight = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: radius * 0.96),
        -0.55,
        0.9,
        false,
      )
      ..close();
    canvas.drawPath(
      highlight,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 0.85,
          colors: const [
            Color(0x55FFFFFF),
            Color(0x18FFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.35, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );

    // Second softer highlight opposite side
    final highlight2 = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: radius * 0.96),
        2.2,
        0.7,
        false,
      )
      ..close();
    canvas.drawPath(
      highlight2,
      Paint()..color = const Color(0x14FFFFFF),
    );

    // Colored reflective streak (makes spin obvious)
    final streakPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.045
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x44D15A55);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * 0.62),
      -0.3,
      0.55,
      false,
      streakPaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * 0.48),
      1.1,
      0.4,
      false,
      streakPaint..color = const Color(0x33CBC9C8),
    );

    // Outer rim
    canvas.drawCircle(
      center,
      radius * 0.985,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = const Color(0x44FFFFFF),
    );

    // Label — slightly off-center pattern so rotation reads
    final labelRadius = radius * 0.23;
    canvas.drawCircle(
      center,
      labelRadius,
      Paint()..color = const Color(0xFFF2F0EC),
    );
    canvas.drawCircle(
      center,
      labelRadius * 0.88,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = const Color(0x33000000),
    );
    // Small logo mark on label (asymmetric)
    final mark = Offset(center.dx + labelRadius * 0.15, center.dy - labelRadius * 0.1);
    canvas.drawCircle(mark, labelRadius * 0.18, Paint()..color = const Color(0xFFA94443));
    canvas.drawCircle(
      Offset(center.dx - labelRadius * 0.25, center.dy + labelRadius * 0.2),
      labelRadius * 0.08,
      Paint()..color = const Color(0xFF2A2A2A),
    );

    // Spindle hole
    canvas.drawCircle(
      center,
      radius * 0.038,
      Paint()..color = const Color(0xFF121212),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

String formatDuration(Duration duration) {
  final minutes = duration.inMinutes.toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
