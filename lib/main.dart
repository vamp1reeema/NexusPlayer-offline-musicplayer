import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';

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
  });

  final int id;
  final String title;
  final String artist;
  final Duration duration;
  final String uri;
  final String? album;
}

enum RepeatMode { off, one }

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
  }

  final OnAudioQuery _audioQuery = OnAudioQuery();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final Random _random = Random();

  List<DeviceTrack> tracks = const [];
  DeviceTrack? currentTrack;
  Duration progress = Duration.zero;
  bool isPlaying = false;
  bool isLoading = true;
  bool isScanning = false;
  bool permissionDenied = false;
  bool playerOpen = false;
  bool shuffle = false;
  RepeatMode repeatMode = RepeatMode.off;
  String? errorMessage;

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;

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
                ),
              )
              .toList();
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

  Future<void> selectTrack(DeviceTrack track) async {
    currentTrack = track;
    progress = Duration.zero;
    playerOpen = true;
    errorMessage = null;
    notifyListeners();

    try {
      await _audioPlayer.setAudioSource(
        AudioSource.uri(
          Uri.parse(track.uri),
          tag: MediaItem(
            id: track.id.toString(),
            title: track.title,
            artist: track.artist,
            duration: track.duration,
            album: track.album,
          ),
        ),
      );
      await _audioPlayer.play();
    } catch (_) {
      errorMessage = 'Этот файл не удалось открыть.';
      isPlaying = false;
      notifyListeners();
    }
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
    if (progress > const Duration(seconds: 4)) {
      await seek(Duration.zero);
      return;
    }
    if (tracks.isEmpty || currentTrack == null) return;
    final index = tracks.indexOf(currentTrack!);
    final previousIndex = index <= 0 ? tracks.length - 1 : index - 1;
    await selectTrack(tracks[previousIndex]);
  }

  Future<void> next() async {
    if (tracks.isEmpty || currentTrack == null) return;
    await _playNext();
  }

  void backToLibrary() {
    playerOpen = false;
    notifyListeners();
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    notifyListeners();
  }

  void toggleRepeat() {
    repeatMode = repeatMode == RepeatMode.off ? RepeatMode.one : RepeatMode.off;
    notifyListeners();
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
    if (tracks.isEmpty || currentTrack == null) return;
    final currentIndex = tracks.indexOf(currentTrack!);
    var nextIndex = currentIndex + 1;
    if (shuffle && tracks.length > 1) {
      do {
        nextIndex = _random.nextInt(tracks.length);
      } while (nextIndex == currentIndex);
    } else if (nextIndex >= tracks.length) {
      nextIndex = 0;
    }
    await selectTrack(tracks[nextIndex]);
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

        return PopScope(
          canPop: !showPlayer,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            // System back while player is open → return to track list
            if (showPlayer) {
              controller.backToLibrary();
            }
          },
          child: showPlayer
              ? PlayerScreen(controller: controller)
              : LibraryScreen(controller: controller),
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
  int tab = 1; // 0 = playlists/queue, 1 = full track list (default)
  String query = '';

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
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
                          isPlaylist: tab == 0,
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
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              tab == 0 ? 'Очередь на сегодня' : 'Список треков',
                              style: const TextStyle(
                                color: text,
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${visibleTracks.length} / ${controller.tracks.length}',
                              style: const TextStyle(
                                color: muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (controller.isLoading)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: CircularProgressIndicator(color: bloodBright),
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
                          message: 'Попробуйте изменить поисковый запрос.',
                          action: 'Очистить поиск',
                          onPressed: () async => setState(() => query = ''),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 126),
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
                              onTap: () => controller.selectTrack(track),
                            );
                          },
                        ),
                      ),
                  ],
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
    super.key,
  });

  final int index;
  final DeviceTrack track;
  final bool current;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
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
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              color: current ? bloodBright : muted,
              size: 18,
            ),
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
                              style: const TextStyle(
                                color: muted,
                                fontSize: 10,
                              ),
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
              height: 59,
              child: Row(
                children: [
                  _navItem(Icons.album_rounded, 'Плейлист', 0),
                  _navItem(Icons.queue_music_rounded, 'Список треков', 1),
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
            Icon(icon, size: 18, color: selected ? bloodBright : muted),
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

class _VinylStageState extends State<VinylStage>
    with TickerProviderStateMixin {
  late final AnimationController _spinController;
  late final AnimationController _beatController;
  bool _wasPlaying = false;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    _beatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );

    if (widget.isPlaying) {
      _spinController.repeat();
      _startBeat();
    }
    _wasPlaying = widget.isPlaying;
  }

  void _startBeat() {
    _beatController.repeat(reverse: true);
  }

  void _stopBeat() {
    _beatController.stop();
    _beatController.animateTo(0, duration: const Duration(milliseconds: 300));
  }

  @override
  void didUpdateWidget(covariant VinylStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying == _wasPlaying) return;
    _wasPlaying = widget.isPlaying;

    if (widget.isPlaying) {
      // Smooth start spinning
      _spinController.repeat();
      _startBeat();
    } else {
      // Smooth stop
      _spinController.stop();
      _stopBeat();
    }
  }

  @override
  void dispose() {
    _spinController.dispose();
    _beatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = min(constraints.maxWidth, constraints.maxHeight);
        return Container(
          width: size,
          height: size,
          padding: EdgeInsets.all(size * .08),
          decoration: BoxDecoration(
            color: const Color(0xFF0B090A),
            border: Border.all(color: const Color(0x1ACBC9C8)),
          ),
          child: AnimatedBuilder(
            animation: Listenable.merge([_spinController, _beatController]),
            builder: (_, child) {
              // Slight beat "jerk" — scale + tiny wobble
              final beat = _beatController.value;
              final scale = 1.0 + (beat * 0.018);
              final wobble = (beat - 0.5) * 0.012;

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

/// Black vinyl with white label — matches the reference photo
class VinylPainter extends CustomPainter {
  const VinylPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2;

    // Main black disc with subtle radial gradient
    final discPaint = Paint()
      ..shader = RadialGradient(
        colors: const [
          Color(0xFF2A2A2A),
          Color(0xFF111111),
          Color(0xFF050505),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, discPaint);

    // Fine grooves
    final groovePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    for (var i = 0; i < 28; i++) {
      final t = 0.22 + (i / 28) * 0.72;
      final alpha = (i.isEven ? 0.14 : 0.07);
      groovePaint.color = Color.fromRGBO(255, 255, 255, alpha);
      canvas.drawCircle(center, radius * t, groovePaint);
    }

    // Outer rim highlight
    canvas.drawCircle(
      center,
      radius * 0.985,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0x33FFFFFF),
    );

    // White center label
    final labelRadius = radius * 0.22;
    canvas.drawCircle(
      center,
      labelRadius,
      Paint()..color = const Color(0xFFF5F5F5),
    );

    // Soft inner shadow on label
    canvas.drawCircle(
      center,
      labelRadius * 0.92,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0x22000000),
    );

    // Center spindle hole
    canvas.drawCircle(
      center,
      radius * 0.035,
      Paint()..color = const Color(0xFF1A1A1A),
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
