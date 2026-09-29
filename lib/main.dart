import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ───────────────────────── Theme tokens ─────────────────────────
// Neutral surfaces are constant; the accent trio is re-derived from the
// artwork of the current song (Material You style, like the mockups).
Color bg = const Color(0xFF0E0F12);
Color panel = const Color(0xFF15171B);
Color panel2 = const Color(0xFF202329);
const muted = Color(0xFF9DA3AD);
Color accent = const Color(0xFF69B9FF);
Color onAccent = const Color(0xFF07131D);
Color tonal = const Color(0xFF263746);

double _uiRadiusFactor = 1.0;
bool _compactRows = false;
bool _showArtworkInLists = true;

double uiRadius(double base) => (base * _uiRadiusFactor).clamp(4.0, 40.0);

final GlobalKey<ScaffoldMessengerState> messengerKey = GlobalKey<ScaffoldMessengerState>();
MusicStore? _storeRef;

void toast(String msg, {bool undo = false}) {
  final m = messengerKey.currentState;
  if (m == null) return;
  m.clearSnackBars();
  m.showSnackBar(SnackBar(
    content: Text(msg),
    behavior: SnackBarBehavior.floating,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 150),
    duration: const Duration(seconds: 3),
    action: undo ? SnackBarAction(label: 'Undo', onPressed: () => _storeRef?.undoQueue()) : null,
  ));
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const VirgoMusicApp());
}

// ───────────────────────── Model ─────────────────────────
class Song {
  final int id;
  final String title, artist, album;
  final String? uri, artAsset, year;
  final int? albumId;
  final Duration duration;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    this.uri,
    this.artAsset,
    this.year,
    this.albumId,
    this.duration = const Duration(minutes: 3, seconds: 10),
  });

  String get primaryArtist => artist.split(RegExp(r',|&| feat\.')).first.trim();
}

const List<Song> _demo = [
  Song(id: 11, title: 'Inner Light', artist: 'Elderbrook, Bob Moses', album: 'Innerlight EP', year: '2021', artAsset: 'assets/covers/innerlight.jpg', duration: Duration(minutes: 4, seconds: 18)),
  Song(id: 12, title: 'I’ll Find My Way To You', artist: 'Elderbrook, Emmit Fenn', album: 'Innerlight EP', year: '2021', artAsset: 'assets/covers/innerlight.jpg', duration: Duration(minutes: 4, seconds: 25)),
  Song(id: 13, title: 'Broken Mirror', artist: 'Elderbrook', album: 'Innerlight EP', year: '2021', artAsset: 'assets/covers/innerlight.jpg', duration: Duration(minutes: 3, seconds: 8)),
  Song(id: 14, title: 'Inner Light (Extended Mix)', artist: 'Elderbrook, Bob Moses', album: 'Innerlight EP', year: '2021', artAsset: 'assets/covers/innerlight.jpg', duration: Duration(minutes: 5, seconds: 40)),
  Song(id: 1, title: 'Without You', artist: 'NEFFEX', album: 'Without You', artAsset: 'assets/covers/without_you.jpg', duration: Duration(minutes: 2, seconds: 40)),
  Song(id: 2, title: 'Free Me', artist: 'NEFFEX', album: 'Without You', artAsset: 'assets/covers/without_you.jpg', duration: Duration(minutes: 2, seconds: 18)),
  Song(id: 3, title: 'Built to Last', artist: 'NEFFEX', album: 'Without You', artAsset: 'assets/covers/without_you.jpg', duration: Duration(minutes: 3, seconds: 0)),
  Song(id: 4, title: "Girls Don't Cry", artist: 'Elza Kanzaki', album: 'ELZA2', year: '2024', artAsset: 'assets/covers/elza2.jpg', duration: Duration(minutes: 3, seconds: 32)),
  Song(id: 5, title: 'Toxic', artist: 'Elza Kanzaki', album: 'ELZA2', year: '2024', artAsset: 'assets/covers/elza2.jpg', duration: Duration(minutes: 3, seconds: 48)),
  Song(id: 6, title: 'Oh Unhappy Day', artist: 'Elza Kanzaki', album: 'ELZA2', year: '2024', artAsset: 'assets/covers/elza2.jpg', duration: Duration(minutes: 3, seconds: 38)),
  Song(id: 7, title: 'Affection', artist: 'Masaru Yokoyama', album: 'Soundtrack', artAsset: 'assets/covers/trending.jpg', duration: Duration(minutes: 4, seconds: 17)),
  Song(id: 8, title: 'Acrophobia', artist: 'Masaru Yokoyama', album: 'Soundtrack', artAsset: 'assets/covers/mellow_pop.jpg', duration: Duration(minutes: 3, seconds: 40)),
  Song(id: 9, title: 'Beat Your Heart', artist: 'Masaru Yokoyama', album: 'Soundtrack', artAsset: 'assets/covers/trending.jpg', duration: Duration(minutes: 3, seconds: 18)),
  Song(id: 10, title: 'Till I Collapse', artist: 'Eminem', album: 'The Eminem Show', artAsset: 'assets/covers/mellow_pop.jpg', duration: Duration(minutes: 4, seconds: 58)),
];

// ───────────────────────── Store ─────────────────────────
class MusicStore extends ChangeNotifier {
  final OnAudioQuery query = OnAudioQuery();
  final AudioPlayer player = AudioPlayer();

  List<Song> songs = [];
  List<Song> queue = [];
  int qIndex = -1;
  bool playing = false, shuffle = false, repeat = false;
  Duration dur = Duration.zero;
  final ValueNotifier<double> progressN = ValueNotifier<double>(0);

  final Set<int> liked = {};
  final Set<String> savedAlbums = {};
  List<int> history = [];
  final Map<String, List<int>> playlists = {};

  List<Song>? _undoQueue;
  int _undoIndex = -1;
  SharedPreferences? _prefs;
  Timer? _sim;
  final math.Random _rnd = math.Random();
  final Set<int> _shufflePlayed = {};

  // Appearance preferences. These only affect presentation; playback and motion stay unchanged.
  bool dynamicArtworkColor = true;
  String themePreset = 'Midnight';
  Color customAccent = const Color(0xFF69B9FF);
  double cardRadius = 1.0;
  bool compactRows = false;
  bool showArtworkInLists = true;
  bool floatingPlayer = true; // NO-mockup layout (floating cover, pill controls)
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration?>? _durSub;

  MusicStore() {
    _storeRef = this;
    songs = [..._demo];
    _posSub = player.positionStream.listen((p) {
      if (!_real || dur.inMilliseconds <= 0) return;
      progressN.value = (p.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0).toDouble();
    });
    _durSub = player.durationStream.listen((d) {
      if (_real && d != null && d.inMilliseconds > 0) {
        dur = d;
        notifyListeners();
      }
    });
    _stateSub = player.playerStateStream.listen((s) {
      if (!_real) return;
      if (s.processingState == ProcessingState.completed) {
        _onEnded();
        return;
      }
      if (playing != s.playing) {
        playing = s.playing;
        notifyListeners();
      }
    });
  }

  // ── derived data
  Song? get current => (qIndex >= 0 && qIndex < queue.length) ? queue[qIndex] : null;
  bool get _real => current?.uri != null && current!.uri!.isNotEmpty;
  Song? get upNext => (qIndex >= 0 && qIndex + 1 < queue.length) ? queue[qIndex + 1] : null;
  List<String> get albumNames => songs.map((s) => s.album).toSet().toList();
  List<Song> albumSongs(String a) => songs.where((s) => s.album == a).toList();
  List<Song> get albumReps => albumNames.map((a) => albumSongs(a).first).toList();
  List<String> get artistNames => songs.map((s) => s.primaryArtist).toSet().toList();
  List<Song> artistSongs(String a) => songs.where((s) => s.primaryArtist == a).toList();
  Song? songById(int id) {
    for (final s in songs) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<Song> get likedSongs => songs.where((s) => liked.contains(s.id)).toList();
  List<Song> get historySongs => history.map(songById).whereType<Song>().toList();
  List<Song> playlistSongs(String name) => (playlists[name] ?? []).map(songById).whereType<Song>().toList();

  // ── persistence
  Future<void> loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    liked.addAll(_safeIntList(_prefs!.getStringList('liked')));
    savedAlbums.addAll(_prefs!.getStringList('saved_albums') ?? []);
    history = _safeIntList(_prefs!.getStringList('history'));
    final raw = _prefs!.getString('playlists');
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        m.forEach((k, v) {
          if (v is List) {
            playlists[k] = v.whereType<num>().map((e) => e.toInt()).toList();
          }
        });
      } catch (_) {}
    }

    dynamicArtworkColor = _prefs!.getBool('dynamic_artwork_color') ?? true;
    themePreset = _prefs!.getString('theme_preset') ?? 'Midnight';
    customAccent = _colorFromInt(_prefs!.getInt('custom_accent'), const Color(0xFF69B9FF));
    cardRadius = (_prefs!.getDouble('card_radius') ?? 1.0).clamp(.65, 1.35);
    compactRows = _prefs!.getBool('compact_rows') ?? false;
    showArtworkInLists = _prefs!.getBool('show_artwork_lists') ?? true;
    floatingPlayer = _prefs!.getBool('floating_player') ?? true;
    _applyAppearance(notify: false);
    notifyListeners();
  }

  List<int> _safeIntList(List<String>? values) {
    if (values == null) return <int>[];
    return values.map(int.tryParse).whereType<int>().toList();
  }

  Color _colorFromInt(int? value, Color fallback) => value == null ? fallback : Color(value);

  void _applyAppearance({bool notify = true}) {
    final presets = <String, List<Color>>{
      'Midnight': [const Color(0xFF0E0F12), const Color(0xFF15171B), const Color(0xFF202329)],
      'AMOLED': [Colors.black, const Color(0xFF090909), const Color(0xFF151515)],
      'Ocean': [const Color(0xFF07131D), const Color(0xFF0D202D), const Color(0xFF173547)],
      'Plum': [const Color(0xFF130D18), const Color(0xFF1D1424), const Color(0xFF2A1C33)],
      'Forest': [const Color(0xFF09130F), const Color(0xFF101D17), const Color(0xFF193025)],
      'Graphite': [const Color(0xFF111111), const Color(0xFF1B1B1B), const Color(0xFF292929)],
    };
    final colors = presets[themePreset] ?? presets['Midnight']!;
    bg = colors[0];
    panel = colors[1];
    panel2 = colors[2];
    accent = customAccent;
    onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;
    tonal = Color.lerp(panel2, accent, .24) ?? panel2;
    _uiRadiusFactor = cardRadius;
    _compactRows = compactRows;
    _showArtworkInLists = showArtworkInLists;
    if (notify) notifyListeners();
  }

  void _saveAppearance() {
    final p = _prefs;
    if (p == null) return;
    p.setBool('dynamic_artwork_color', dynamicArtworkColor);
    p.setString('theme_preset', themePreset);
    p.setInt('custom_accent', customAccent.value);
    p.setDouble('card_radius', cardRadius);
    p.setBool('compact_rows', compactRows);
    p.setBool('show_artwork_lists', showArtworkInLists);
    p.setBool('floating_player', floatingPlayer);
  }

  void setThemePreset(String value) {
    themePreset = value;
    _applyAppearance(notify: false);
    _saveAppearance();
    notifyListeners();
  }

  void setAccent(Color value) {
    customAccent = value;
    _applyAppearance(notify: false);
    _saveAppearance();
    notifyListeners();
  }

  void setDynamicArtwork(bool value) {
    dynamicArtworkColor = value;
    _applyAppearance(notify: false);
    _saveAppearance();
    notifyListeners();
    if (value && current != null) unawaited(_updateTheme(current!));
  }

  void setCardRadius(double value) {
    cardRadius = value.clamp(.65, 1.35);
    _applyAppearance(notify: false);
    _saveAppearance();
    notifyListeners();
  }

  void setCompactRows(bool value) {
    compactRows = value;
    _applyAppearance(notify: false);
    _saveAppearance();
    notifyListeners();
  }

  void setShowArtworkInLists(bool value) {
    showArtworkInLists = value;
    _applyAppearance(notify: false);
    _saveAppearance();
    notifyListeners();
  }

  void setFloatingPlayer(bool value) {
    floatingPlayer = value;
    _saveAppearance();
    notifyListeners();
  }

  void resetAppearance() {
    floatingPlayer = true;
    dynamicArtworkColor = true;
    themePreset = 'Midnight';
    customAccent = const Color(0xFF69B9FF);
    cardRadius = 1.0;
    compactRows = false;
    showArtworkInLists = true;
    _applyAppearance(notify: false);
    _saveAppearance();
    notifyListeners();
  }

  void _save() {
    final p = _prefs;
    if (p == null) return;
    p.setStringList('liked', liked.map((e) => e.toString()).toList());
    p.setStringList('saved_albums', savedAlbums.toList());
    p.setStringList('history', history.map((e) => e.toString()).toList());
    p.setString('playlists', jsonEncode(playlists));
  }

  void toggleLike(Song s) {
    liked.contains(s.id) ? liked.remove(s.id) : liked.add(s.id);
    _save();
    notifyListeners();
  }

  void toggleSavedAlbum(String album) {
    savedAlbums.contains(album) ? savedAlbums.remove(album) : savedAlbums.add(album);
    _save();
    notifyListeners();
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    _shufflePlayed.clear();
    if (shuffle && qIndex >= 0) _shufflePlayed.add(qIndex);
    notifyListeners();
  }

  void toggleRepeat() {
    repeat = !repeat;
    notifyListeners();
  }

  // ── library scan
  Future<void> scanLocalMusic() async {
    try {
      var ok = await query.permissionsStatus();
      if (!ok) ok = await query.requestPermission();
      if (!ok) return;
      final raw = await query.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      if (raw.isEmpty) return;
      songs = raw
          .take(2000)
          .map((s) => Song(
                id: s.id,
                title: s.title,
                artist: (s.artist == null || s.artist == '<unknown>') ? 'Unknown artist' : s.artist!,
                album: s.album ?? 'Unknown album',
                uri: s.uri,
                albumId: s.albumId,
                duration: Duration(milliseconds: s.duration ?? 0),
              ))
          .toList();
      notifyListeners();
    } catch (_) {
      // Keep the bundled demo library when permission or query is unavailable.
    }
  }

  // ── artwork-derived accent
  Future<void> _updateTheme(Song s) async {
    if (!dynamicArtworkColor) return;
    try {
      ImageProvider? p;
      if (s.artAsset != null) {
        p = AssetImage(s.artAsset!);
      } else if (s.albumId != null) {
        final Uint8List? b = await query.queryArtwork(s.albumId!, ArtworkType.ALBUM, size: 200);
        if (b != null && b.isNotEmpty) p = MemoryImage(b);
      }
      if (p == null) return;
      final cs = await ColorScheme.fromImageProvider(provider: p, brightness: Brightness.dark);
      if (current?.id != s.id) return;
      accent = cs.primary;
      onAccent = cs.onPrimary;
      tonal = cs.secondaryContainer;
      notifyListeners();
    } catch (_) {}
  }

  // ── playback
  void playSong(Song s, List<Song> context) {
    final i = context.indexWhere((x) => x.id == s.id);
    if (i < 0) {
      playQueue([s], 0);
    } else {
      playQueue(context, i);
    }
  }

  void playQueue(List<Song> list, int index) {
    if (list.isEmpty) return;
    queue = [...list];
    _undoQueue = null;
    _shufflePlayed.clear();
    final start = index.clamp(0, list.length - 1);
    if (shuffle) _shufflePlayed.add(start);
    _startAt(start);
  }

  void shuffleAll(List<Song> list) {
    if (list.isEmpty) return;
    shuffle = true;
    final start = _rnd.nextInt(list.length);
    queue = [...list];
    _undoQueue = null;
    _shufflePlayed.clear();
    _shufflePlayed.add(start);
    _startAt(start);
    notifyListeners();
  }

  Future<void> _startAt(int i) async {
    if (i < 0 || i >= queue.length) return;
    qIndex = i;
    final song = queue[i];
    _sim?.cancel();
    progressN.value = 0;
    dur = song.duration;
    playing = true;
    history.remove(song.id);
    history.insert(0, song.id);
    if (history.length > 50) history = history.sublist(0, 50);
    _save();
    notifyListeners();
    unawaited(_updateTheme(song));
    if (song.uri != null && song.uri!.isNotEmpty) {
      try {
        await player.setAudioSource(AudioSource.uri(Uri.parse(song.uri!)));
        unawaited(player.play());
      } catch (_) {
        playing = false;
        notifyListeners();
      }
    } else {
      try {
        await player.stop();
      } catch (_) {}
      _startSim();
    }
  }

  void _startSim() {
    _sim?.cancel();
    _sim = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!playing || current == null || _real) return;
      final ms = dur.inMilliseconds;
      if (ms <= 0) return;
      final v = progressN.value + 250 / ms;
      if (v >= 1) {
        _sim?.cancel();
        progressN.value = 1;
        _onEnded();
      } else {
        progressN.value = v;
      }
    });
  }

  int? _nextIndex() {
    if (queue.isEmpty) return null;

    if (shuffle && queue.length > 1) {
      final available = <int>[];
      for (var i = 0; i < queue.length; i++) {
        if (!_shufflePlayed.contains(i)) available.add(i);
      }

      if (available.isEmpty) {
        if (!repeat) return null;
        _shufflePlayed.clear();
        if (qIndex >= 0) _shufflePlayed.add(qIndex);
        for (var i = 0; i < queue.length; i++) {
          if (i != qIndex) available.add(i);
        }
      }

      final j = available[_rnd.nextInt(available.length)];
      _shufflePlayed.add(j);
      return j;
    }

    if (qIndex < queue.length - 1) return qIndex + 1;
    return repeat ? 0 : null;
  }

  void _onEnded() {
    final n = _nextIndex();
    if (n == null) {
      playing = false;
      progressN.value = 0;
      _sim?.cancel();
      if (_real) player.pause();
      notifyListeners();
    } else {
      _startAt(n);
    }
  }

  Future<void> toggle() async {
    if (current == null) return;
    if (_real) {
      final will = !player.playing || player.processingState == ProcessingState.completed;
      playing = will;
      notifyListeners();
      if (will) {
        if (player.processingState == ProcessingState.completed) await player.seek(Duration.zero);
        unawaited(player.play());
      } else {
        await player.pause();
      }
      return;
    }
    playing = !playing;
    if (playing) {
      if (progressN.value >= 1) progressN.value = 0;
      _startSim();
    } else {
      _sim?.cancel();
    }
    notifyListeners();
  }

  Future<void> seek(double v) async {
    final p = v.clamp(0.0, 1.0).toDouble();
    progressN.value = p;
    if (_real) {
      try {
        await player.seek(Duration(milliseconds: (dur.inMilliseconds * p).round()));
      } catch (_) {}
    }
  }

  void skipNext() {
    final n = _nextIndex();
    if (n != null) _startAt(n);
  }

  void skipPrev() {
    if (current == null) return;
    final elapsedMs = dur.inMilliseconds * progressN.value;
    if (elapsedMs > 3000 || qIndex <= 0) {
      seek(0);
    } else {
      _startAt(qIndex - 1);
    }
  }

  void jumpTo(int i) {
    if (i < 0 || i >= queue.length) return;
    if (shuffle) {
      _shufflePlayed.clear();
      _shufflePlayed.add(i);
    }
    _startAt(i);
  }

  // ── queue operations (with Undo like the recording's snackbar)
  void _snapshot() {
    _undoQueue = [...queue];
    _undoIndex = qIndex;
  }

  void undoQueue() {
    final u = _undoQueue;
    if (u == null) return;
    final cur = current;
    queue = u;
    qIndex = cur == null ? _undoIndex : queue.indexWhere((s) => s.id == cur.id);
    if (qIndex < 0) qIndex = _undoIndex;
    _shufflePlayed.clear();
    if (shuffle && qIndex >= 0) _shufflePlayed.add(qIndex);
    _undoQueue = null;
    notifyListeners();
  }

  void shuffleUpcoming() {
    if (qIndex < 0 || queue.length - qIndex <= 2) return;
    _snapshot();
    final head = queue.sublist(0, qIndex + 1);
    final tail = queue.sublist(qIndex + 1)..shuffle(_rnd);
    queue = [...head, ...tail];
    _shufflePlayed.clear();
    if (shuffle) _shufflePlayed.add(qIndex);
    notifyListeners();
    toast('Queue shuffled', undo: true);
  }

  void clearUpcoming() {
    if (qIndex < 0 || qIndex >= queue.length - 1) return;
    _snapshot();
    queue = queue.sublist(0, qIndex + 1);
    _shufflePlayed.clear();
    if (shuffle) _shufflePlayed.add(qIndex);
    notifyListeners();
    toast('Queue cleared', undo: true);
  }

  void addNext(Song s) {
    if (queue.isEmpty) {
      playQueue([s], 0);
      return;
    }
    queue.insert(qIndex + 1, s);
    _shufflePlayed.clear();
    if (shuffle && qIndex >= 0) _shufflePlayed.add(qIndex);
    notifyListeners();
    toast('Will play next');
  }

  void addToQueue(Song s) {
    if (queue.isEmpty) {
      playQueue([s], 0);
      return;
    }
    queue.add(s);
    _shufflePlayed.clear();
    if (shuffle && qIndex >= 0) _shufflePlayed.add(qIndex);
    notifyListeners();
    toast('Added to queue');
  }

  void saveQueueAsPlaylist() {
    if (queue.isEmpty) return;
    var n = playlists.length + 1;
    while (playlists.containsKey('Queue $n')) {
      n++;
    }
    playlists['Queue $n'] = queue.map((s) => s.id).toList();
    _save();
    notifyListeners();
    toast('Saved as “Queue $n”');
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _durSub?.cancel();
    _sim?.cancel();
    progressN.dispose();
    player.dispose();
    super.dispose();
  }
}

// ───────────────────────── App / shell ─────────────────────────
class VirgoMusicApp extends StatefulWidget {
  const VirgoMusicApp({super.key});
  @override
  State<VirgoMusicApp> createState() => _VirgoMusicAppState();
}

class _VirgoMusicAppState extends State<VirgoMusicApp> {
  final store = MusicStore();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await store.loadPrefs();
      await store.scanLocalMusic();
    });
  }

  @override
  void dispose() {
    store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (_, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Virgo Music',
        scaffoldMessengerKey: messengerKey,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: bg,
          colorScheme: ColorScheme.dark(primary: accent, onPrimary: onAccent, surface: bg, secondaryContainer: tonal),
          fontFamily: 'Roboto',
          splashFactory: InkSparkle.splashFactory,
        ),
        home: RootShell(store: store),
      ),
    );
  }
}

class _R extends StatelessWidget {
  final MusicStore store;
  final Widget Function(BuildContext) builder;
  const _R(this.store, this.builder);
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: store, builder: (c, _) => builder(c));
}

class RootShell extends StatefulWidget {
  final MusicStore store;
  const RootShell({super.key, required this.store});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int index = 0;
  final PageController _tabs = PageController();
  final GlobalKey<NavigatorState> _nav = GlobalKey<NavigatorState>();

  void select(int i) {
    if (i == 4) {
      if (widget.store.current != null) _openPlayer();
      return;
    }
    _nav.currentState?.popUntil((r) => r.isFirst);
    if (i == index) return;
    setState(() => index = i);
    _tabs.animateToPage(i, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
  }

  void _openPlayer() {
    Navigator.of(context, rootNavigator: true).push(_riseRoute(NowPlayingPage(store: widget.store)));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    final store = widget.store;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final n = _nav.currentState;
        if (n != null && n.canPop()) {
          n.pop();
        } else if (index != 0) {
          select(0);
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: bg,
        body: Stack(children: [
          Navigator(
            key: _nav,
            onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => _TabsView(store: store, controller: _tabs)),
          ),
          if (store.current != null)
            Positioned(left: 10, right: 10, bottom: 82 + inset, child: MiniPlayer(store: store, onTap: _openPlayer)),
          Positioned(left: 12, right: 12, bottom: 12 + inset, child: FloatingNav(selected: index, store: store, onSelect: select)),
        ]),
      ),
    );
  }
}

class _TabsView extends StatelessWidget {
  final MusicStore store;
  final PageController controller;
  const _TabsView({required this.store, required this.controller});
  @override
  Widget build(BuildContext context) => SafeArea(
        bottom: false,
        child: PageView(
          controller: controller,
          physics: const NeverScrollableScrollPhysics(),
          children: [HomePage(store: store), SearchPage(store: store), LibraryPage(store: store), SettingsPage(store: store)],
        ),
      );
}

// ───────────────────────── Routes / motion ─────────────────────────
Route<T> _slideRoute<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 270),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, secondary, child) {
        final enter = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        final leave = CurvedAnimation(parent: secondary, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(enter),
          child: SlideTransition(
            position: Tween<Offset>(begin: Offset.zero, end: const Offset(-0.075, 0)).animate(leave),
            child: child,
          ),
        );
      },
    );

Route<T> _riseRoute<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 340),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        final c = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return SlideTransition(position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(c), child: child);
      },
    );

Future<void> _showSheet(BuildContext context, Widget Function(BuildContext) builder) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withOpacity(.58),
    transitionDuration: const Duration(milliseconds: 310),
    pageBuilder: (ctx, a, b) => Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .92),
        child: Material(
          color: panel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(top: false, child: builder(ctx)),
        ),
      ),
    ),
    transitionBuilder: (ctx, animation, secondary, child) {
      final c = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      return SlideTransition(position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(c), child: FadeTransition(opacity: c, child: child));
    },
  );
}

class _PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _PressScale({required this.child, this.onTap});
  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool pressed = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => pressed = true),
        onTapUp: (_) => setState(() => pressed = false),
        onTapCancel: () => setState(() => pressed = false),
        child: AnimatedScale(scale: pressed ? .96 : 1, duration: const Duration(milliseconds: 90), curve: Curves.easeOut, child: widget.child),
      );
}

// ───────────────────────── Shared widgets ─────────────────────────
Widget _art(Song song, double size, double radius, {double? height}) {
  final ph = ColoredBox(color: panel2, child: Center(child: Icon(Icons.music_note_rounded, color: accent)));
  final Widget img = song.artAsset != null
      ? Image.asset(song.artAsset!, fit: BoxFit.cover, cacheWidth: size.isFinite ? (size * 3).round() : null)
      : QueryArtworkWidget(
          id: song.albumId ?? song.id,
          type: song.albumId != null ? ArtworkType.ALBUM : ArtworkType.AUDIO,
          artworkFit: BoxFit.cover,
          artworkBorder: BorderRadius.zero,
          nullArtworkWidget: ph,
        );
  return ClipRRect(borderRadius: BorderRadius.circular(uiRadius(radius)), child: SizedBox(width: size, height: height ?? size, child: img));
}

String _fmt(Duration d) {
  if (d.isNegative) return '0:00';
  return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

String _left(MusicStore s) {
  final i = s.qIndex < 0 ? 0 : s.qIndex;
  final rest = s.queue.skip(i).fold<Duration>(Duration.zero, (a, b) => a + b.duration);
  final m = rest.inMinutes % 60;
  return rest.inHours > 0 ? '${rest.inHours} hr $m min left' : '$m min left';
}

Widget _circleBtn(IconData icon, VoidCallback onTap) => _PressScale(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(color: Colors.white.withOpacity(.14), shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );

Widget _pillBtn(IconData icon, String text, VoidCallback onTap) => _PressScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(uiRadius(22))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: onAccent),
          const SizedBox(width: 8),
          Text(text, style: TextStyle(color: onAccent, fontWeight: FontWeight.w700, fontSize: 13)),
        ]),
      ),
    );

Widget _heading(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 9),
      child: Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
    );

class _TopHeader extends StatelessWidget {
  final String title;
  const _TopHeader({required this.title});
  @override
  Widget build(BuildContext context) => Row(children: [
        Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -.3)),
        const Spacer(),
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(uiRadius(12))),
          child: const Icon(Icons.more_horiz_rounded, size: 20),
        ),
      ]);
}

Widget _rail(BuildContext context, MusicStore store, String title, List<Song> reps) {
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _heading(title),
    SizedBox(
      height: 166,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: reps.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final s = reps[i];
          final tag = 'rail-$title-${s.id}';
          return _PressScale(
            onTap: () => Navigator.of(context).push(_slideRoute(AlbumPage(store: store, album: s.album, heroTag: tag))),
            child: SizedBox(
              width: 122,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Hero(tag: tag, child: _art(s, 122, 14)),
                const SizedBox(height: 7),
                Text(s.album, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.0, fontWeight: FontWeight.w600)),
                Text(s.primaryArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: muted)),
              ]),
            ),
          );
        },
      ),
    ),
  ]);
}

// ───────────────────────── Nav + Mini player ─────────────────────────
class FloatingNav extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  final MusicStore store;
  const FloatingNav({super.key, required this.selected, required this.onSelect, required this.store});

  @override
  Widget build(BuildContext context) {
    final cur = store.current;
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF171A1F).withOpacity(.98),
        borderRadius: BorderRadius.circular(uiRadius(30)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.35), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _item(0, Icons.home_rounded, 'Home'),
        _item(1, Icons.search_rounded, 'Search'),
        _item(2, Icons.library_music_rounded, 'Library'),
        _item(3, Icons.settings_rounded, 'Settings'),
        _PressScale(
          onTap: () => onSelect(4),
          child: cur == null
              ? Container(width: 40, height: 40, decoration: BoxDecoration(shape: BoxShape.circle, color: panel2), child: Icon(Icons.music_note, size: 18, color: accent))
              : _art(cur, 40, 20),
        ),
      ]),
    );
  }

  Widget _item(int id, IconData icon, String label) {
    final active = selected == id;
    return _PressScale(
      onTap: () => onSelect(id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(horizontal: active ? 14 : 10, vertical: 9),
        decoration: BoxDecoration(color: active ? tonal : Colors.transparent, borderRadius: BorderRadius.circular(uiRadius(22))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 22, color: active ? Colors.white : Colors.white70),
          if (active) ...[
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.white)),
          ],
        ]),
      ),
    );
  }
}

class MiniPlayer extends StatelessWidget {
  final MusicStore store;
  final VoidCallback onTap;
  const MiniPlayer({super.key, required this.store, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = store.current!;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF181B20).withOpacity(.99),
          borderRadius: BorderRadius.circular(uiRadius(12)),
          border: Border.all(color: Colors.white.withOpacity(.05)),
        ),
        child: Row(children: [
          Hero(tag: 'player-art', child: _art(s, 48, 10)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: muted)),
              const SizedBox(height: 4),
              SizedBox(
                height: 10,
                width: double.infinity,
                child: ValueListenableBuilder<double>(
                  valueListenable: store.progressN,
                  builder: (_, p, __) => CustomPaint(painter: _WavePainter(p, 0, accent, amp: 2.4, stroke: 3, wavelength: 16, thumbHeight: 0)),
                ),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          _PressScale(
            onTap: store.toggle,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(uiRadius(13))),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 170),
                transitionBuilder: (c, a) => FadeTransition(opacity: a, child: ScaleTransition(scale: a, child: c)),
                child: Icon(store.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(store.playing), color: onAccent),
              ),
            ),
          ),
          _PressScale(onTap: store.skipNext, child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.skip_next_rounded, size: 26))),
        ]),
      ),
    );
  }
}

// ───────────────────────── Rows ─────────────────────────
class SongRow extends StatelessWidget {
  final Song song;
  final MusicStore store;
  final List<Song>? queue;
  final int? number;
  final bool roomy;
  const SongRow({super.key, required this.song, required this.store, this.queue, this.number, this.roomy = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final active = store.current?.id == song.id;
        final Widget lead = number != null
            ? SizedBox(
                width: 30,
                child: Center(
                  child: active ? Icon(Icons.equalizer_rounded, color: accent, size: 22) : Text('$number', style: const TextStyle(fontSize: 15, color: muted)),
                ),
              )
            : (_showArtworkInLists ? _art(song, 44, 9) : Container(width: 44, height: 44, decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(uiRadius(9))), child: Icon(Icons.music_note_rounded, color: accent)));
        return _PressScale(
          onTap: () => store.playSong(song, queue ?? store.songs),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: EdgeInsets.symmetric(horizontal: roomy ? 12 : 10, vertical: 1),
            padding: EdgeInsets.symmetric(horizontal: roomy ? 12 : 6, vertical: _compactRows ? (roomy ? 5 : 2) : (roomy ? 10 : 5)),
            decoration: BoxDecoration(color: active ? tonal.withOpacity(.72) : Colors.transparent, borderRadius: BorderRadius.circular(uiRadius(roomy ? 18 : 10))),
            child: Row(children: [
              lead,
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: roomy ? 15.5 : 13.2, fontWeight: active ? FontWeight.w600 : FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: roomy ? 12.5 : 11, color: muted)),
                ]),
              ),
              Text(_fmt(song.duration), style: const TextStyle(fontSize: 12, color: muted)),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _showSongMenu(context, song, store),
                child: const Padding(padding: EdgeInsets.fromLTRB(8, 6, 2, 6), child: Icon(Icons.more_vert_rounded, size: 20, color: Colors.white60)),
              ),
            ]),
          ),
        );
      },
    );
  }
}

void _showSongMenu(BuildContext context, Song song, MusicStore store, {bool player = false}) {
  _showSheet(context, (ctx) {
    Widget tile(IconData icon, String text, VoidCallback run, {String? trailing}) => ListTile(
          leading: Icon(icon, color: accent),
          title: Text(text),
          trailing: trailing == null ? null : Text(trailing, style: const TextStyle(color: muted)),
          onTap: () {
            Navigator.pop(ctx);
            run();
          },
        );
    return ListenableBuilder(
      listenable: store,
      builder: (_, __) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                _art(song, 52, 12),
                const SizedBox(width: 12),
                Expanded(child: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16))),
              ]),
            ),
            const SizedBox(height: 8),
            tile(store.liked.contains(song.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded, store.liked.contains(song.id) ? 'Remove from liked' : 'Add to liked', () => store.toggleLike(song)),
            tile(Icons.playlist_play_rounded, 'Play next', () => store.addNext(song)),
            tile(Icons.queue_rounded, 'Add to queue', () => store.addToQueue(song)),
            tile(Icons.shuffle_rounded, "Shuffle what's left", store.shuffleUpcoming),
            tile(Icons.playlist_add_rounded, 'Save queue as playlist', store.saveQueueAsPlaylist),
            tile(Icons.clear_all_rounded, 'Clear queue', store.clearUpcoming),
            if (player) ...[
              tile(Icons.shuffle_rounded, 'Shuffle mode', store.toggleShuffle, trailing: store.shuffle ? 'On' : 'Off'),
              tile(Icons.repeat_rounded, 'Repeat all', store.toggleRepeat, trailing: store.repeat ? 'On' : 'Off'),
            ],
          ]),
        ),
      ),
    );
  });
}

// ───────────────────────── Home ─────────────────────────
class HomePage extends StatelessWidget {
  final MusicStore store;
  const HomePage({super.key, required this.store});

  @override
  Widget build(BuildContext context) => _R(store, (ctx) {
        final reps = store.albumReps;
        final quick = store.songs.take(6).toList();
        return CustomScrollView(physics: const BouncingScrollPhysics(), slivers: [
          const SliverPadding(padding: EdgeInsets.fromLTRB(16, 18, 16, 16), sliver: SliverToBoxAdapter(child: _TopHeader(title: 'Home'))),
          SliverToBoxAdapter(child: _rail(ctx, store, 'New releases', reps)),
          SliverPadding(padding: const EdgeInsets.only(top: 18), sliver: SliverToBoxAdapter(child: _rail(ctx, store, 'Throwbacks', reps.reversed.toList()))),
          SliverPadding(
            padding: const EdgeInsets.only(top: 18),
            sliver: SliverToBoxAdapter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _heading('Quick picks'),
                ...quick.map((s) => SongRow(song: s, store: store, queue: quick)),
              ]),
            ),
          ),
          SliverPadding(padding: const EdgeInsets.only(top: 22, bottom: 170), sliver: SliverToBoxAdapter(child: _rail(ctx, store, 'Low key vibes', reps.skip(1).toList()))),
        ]);
      });
}

// ───────────────────────── Search ─────────────────────────
class SearchPage extends StatefulWidget {
  final MusicStore store;
  const SearchPage({super.key, required this.store});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final controller = TextEditingController();
  int tab = 0;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _R(widget.store, (ctx) {
        final s = widget.store;
        final tokens = controller.text.toLowerCase().split(' ').where((t) => t.isNotEmpty).toList();
        bool match(String hay) {
          final h = hay.toLowerCase();
          return tokens.every((t) => h.contains(t));
        }

        Widget body;
        switch (tab) {
          case 0: {
            final list = s.songs.where((x) => match('${x.title} ${x.artist} ${x.album}')).toList();
            body = ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 170),
              itemCount: list.length,
              itemBuilder: (_, i) => SongRow(song: list[i], store: s, queue: list),
            );
            break;
          }
          case 1: {
            final list = s.albumNames.where((a) => match('$a ${s.albumSongs(a).first.artist}')).toList();
            body = ListView.builder(
              padding: const EdgeInsets.only(bottom: 170),
              itemCount: list.length,
              itemBuilder: (_, i) {
                final rep = s.albumSongs(list[i]).first;
                return _entityRow(_art(rep, 46, 10), list[i], rep.primaryArtist, () => Navigator.of(ctx).push(_slideRoute(AlbumPage(store: s, album: list[i]))));
              },
            );
            break;
          }
          case 2: {
            final list = s.artistNames.where(match).toList();
            body = ListView.builder(
              padding: const EdgeInsets.only(bottom: 170),
              itemCount: list.length,
              itemBuilder: (_, i) {
                final rep = s.artistSongs(list[i]).first;
                return _entityRow(ClipOval(child: _art(rep, 46, 0)), list[i], 'Artist', () => Navigator.of(ctx).push(_slideRoute(ArtistPage(store: s, artist: list[i]))));
              },
            );
            break;
          }
          case 3: {
            final list = s.playlists.keys.where(match).toList();
            body = list.isEmpty
                ? const Center(child: Text('No playlists yet', style: TextStyle(color: muted)))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 170),
                    itemCount: list.length,
                    itemBuilder: (_, i) => _entityRow(
                      Container(width: 46, height: 46, decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(uiRadius(10))), child: Icon(Icons.queue_music_rounded, color: accent)),
                      list[i],
                      '${s.playlists[list[i]]!.length} songs',
                      () => Navigator.of(ctx).push(_slideRoute(SongListPage(store: s, title: list[i], source: (st) => st.playlistSongs(list[i])))),
                    ),
                  );
            break;
          }
          default:
            body = const Center(child: Text('Videos are not available offline', style: TextStyle(color: muted)));
        }

        return Column(children: [
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: controller,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded, size: 22),
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () {
                          controller.clear();
                          setState(() {});
                        },
                      ),
                hintText: 'Search songs, albums, artists',
                filled: true,
                fillColor: panel2,
                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(uiRadius(14)), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 34,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: 5,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => ChoiceChip(
                label: Text(['Songs', 'Albums', 'Artists', 'Playlists', 'Videos'][i], style: TextStyle(fontSize: 12, color: tab == i ? onAccent : Colors.white70)),
                selected: tab == i,
                onSelected: (_) => setState(() => tab = i),
                selectedColor: accent,
                backgroundColor: panel2,
                showCheckmark: false,
                side: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(child: body),
        ]);
      });
}

Widget _entityRow(Widget lead, String title, String sub, VoidCallback onTap) => _PressScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          lead,
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: muted)),
            ]),
          ),
        ]),
      ),
    );

// ───────────────────────── Library ─────────────────────────
class LibraryPage extends StatelessWidget {
  final MusicStore store;
  const LibraryPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) => _R(store, (ctx) {
        final s = store;
        final liked = s.likedSongs;
        final saved = s.savedAlbums.isEmpty ? s.albumReps : s.savedAlbums.where((a) => s.albumSongs(a).isNotEmpty).map((a) => s.albumSongs(a).first).toList();
        Widget tile(IconData icon, String title, String sub, VoidCallback onTap) => _PressScale(
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(uiRadius(18))),
                child: Row(children: [
                  Icon(icon, size: 22, color: accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      if (sub.isNotEmpty) Text(sub, style: const TextStyle(fontSize: 11, color: muted)),
                    ]),
                  ),
                ]),
              ),
            );
        return CustomScrollView(physics: const BouncingScrollPhysics(), slivers: [
          const SliverPadding(padding: EdgeInsets.fromLTRB(16, 18, 16, 0), sliver: SliverToBoxAdapter(child: _TopHeader(title: 'Library'))),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
            sliver: SliverToBoxAdapter(
              child: _PressScale(
                onTap: () => Navigator.of(ctx).push(_slideRoute(SongListPage(store: s, title: 'Liked songs', source: (st) => st.likedSongs))),
                child: Container(
                  height: 84,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  decoration: BoxDecoration(color: tonal, borderRadius: BorderRadius.circular(uiRadius(24))),
                  child: Row(children: [
                    const Icon(Icons.favorite_rounded, color: Colors.white, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Liked songs', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                        Text('${liked.length} songs', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                      ]),
                    ),
                    _PressScale(
                      onTap: () => s.playQueue(liked, 0),
                      child: Container(width: 46, height: 46, decoration: BoxDecoration(color: accent, shape: BoxShape.circle), child: Icon(Icons.play_arrow_rounded, color: onAccent)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            sliver: SliverGrid(
              delegate: SliverChildListDelegate([
                tile(Icons.album_rounded, 'Albums', '${s.albumNames.length} albums', () => Navigator.of(ctx).push(_slideRoute(AlbumsPage(store: s)))),
                tile(Icons.queue_music_rounded, 'Playlists', '${s.playlists.length} playlists', () => Navigator.of(ctx).push(_slideRoute(PlaylistsPage(store: s)))),
                tile(Icons.person_rounded, 'Artists', '${s.artistNames.length} artists', () => Navigator.of(ctx).push(_slideRoute(ArtistsPage(store: s)))),
                tile(Icons.history_rounded, 'History', '${s.history.length} played', () => Navigator.of(ctx).push(_slideRoute(SongListPage(store: s, title: 'History', source: (st) => st.historySongs)))),
              ]),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 2.3),
            ),
          ),
          SliverPadding(padding: const EdgeInsets.only(top: 24, bottom: 170), sliver: SliverToBoxAdapter(child: _rail(ctx, s, 'Recently saved', saved))),
        ]);
      });
}

// ───────────────────────── Settings ─────────────────────────
class SettingsPage extends StatelessWidget {
  final MusicStore store;
  const SettingsPage({super.key, required this.store});

  static const _accentPresets = <Color>[
    Color(0xFF69B9FF), Color(0xFF8B7CFF), Color(0xFFFF6B9A), Color(0xFFFFB84D),
    Color(0xFF59D68D), Color(0xFF35C9D9), Color(0xFFE96CFF), Color(0xFFFF5C5C),
  ];

  Future<void> _customAccent(BuildContext context) async {
    Color value = store.customAccent;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final r = value.red.toDouble();
          final g = value.green.toDouble();
          final b = value.blue.toDouble();
          return AlertDialog(
            backgroundColor: panel,
            title: const Text('Custom accent'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(height: 52, decoration: BoxDecoration(color: value, borderRadius: BorderRadius.circular(uiRadius(16)))),
              const SizedBox(height: 18),
              _rgbSlider('Red', r, (v) => setState(() => value = Color.fromARGB(255, v.round(), value.green, value.blue))),
              _rgbSlider('Green', g, (v) => setState(() => value = Color.fromARGB(255, value.red, v.round(), value.blue))),
              _rgbSlider('Blue', b, (v) => setState(() => value = Color.fromARGB(255, value.red, value.green, v.round()))),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () { store.setAccent(value); Navigator.pop(ctx); }, child: const Text('Apply')),
            ],
          );
        },
      ),
    );
  }

  Widget _rgbSlider(String label, double value, ValueChanged<double> onChanged) => Row(children: [
    SizedBox(width: 48, child: Text(label, style: const TextStyle(fontSize: 12, color: muted))),
    Expanded(child: Slider(value: value, min: 0, max: 255, onChanged: onChanged)),
    SizedBox(width: 30, child: Text(value.round().toString(), textAlign: TextAlign.end)),
  ]);

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(left: 4, bottom: 8), child: Text(title, style: TextStyle(color: accent, fontSize: 13, fontWeight: FontWeight.w700))),
      Container(
        decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(uiRadius(22))),
        child: child,
      ),
    ]),
  );

  Widget _tile(IconData icon, String title, String subtitle, {Widget? trailing, VoidCallback? onTap}) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    leading: Container(width: 42, height: 42, decoration: BoxDecoration(color: tonal.withOpacity(.7), borderRadius: BorderRadius.circular(uiRadius(13))), child: Icon(icon, color: accent)),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 12, color: muted)),
    trailing: trailing,
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) => _R(store, (ctx) {
    const presets = ['Midnight', 'AMOLED', 'Ocean', 'Plum', 'Forest', 'Graphite'];
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 170),
      children: [
        const Text('Settings', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('Make Virgo Music yours', style: TextStyle(color: muted)),
        const SizedBox(height: 22),

        _section('THEME', Column(children: [
          _tile(Icons.palette_rounded, 'Theme preset', store.themePreset, onTap: () => showModalBottomSheet<void>(
            context: context,
            backgroundColor: panel,
            showDragHandle: true,
            builder: (ctx) => SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), shrinkWrap: true, children: [
              const Text('Choose a theme', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              ...presets.map((name) => ListTile(
                leading: Icon(name == store.themePreset ? Icons.radio_button_checked : Icons.radio_button_off, color: accent),
                title: Text(name),
                onTap: () { store.setThemePreset(name); Navigator.pop(ctx); },
              )),
            ])),
          )),
          const Divider(height: 1, color: Colors.white10),
          _tile(Icons.color_lens_rounded, 'Accent colour', 'Changes buttons, highlights and controls', trailing: GestureDetector(
            onTap: () => _customAccent(context),
            child: Container(width: 34, height: 34, decoration: BoxDecoration(color: store.customAccent, shape: BoxShape.circle, border: Border.all(color: Colors.white24))),
          ), onTap: () => _customAccent(context)),
          const Divider(height: 1, color: Colors.white10),
          _tile(Icons.auto_awesome_rounded, 'Artwork colours', 'Automatically match the accent to the current cover', trailing: Switch(value: store.dynamicArtworkColor, onChanged: store.setDynamicArtwork)),
          const Divider(height: 1, color: Colors.white10),
          Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 10), child: Row(children: [
            const Expanded(child: Text('Quick accent presets', style: TextStyle(fontWeight: FontWeight.w600))),
            Text('tap a colour', style: const TextStyle(fontSize: 11, color: muted)),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Wrap(spacing: 12, runSpacing: 10, children: _accentPresets.map((c) => GestureDetector(
            onTap: () => store.setAccent(c),
            child: Container(width: 38, height: 38, decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: store.customAccent.value == c.value ? Colors.white : Colors.transparent, width: 2))),
          )).toList())),
        ])),

        _section('LAYOUT', Column(children: [
          _tile(Icons.rounded_corner_rounded, 'Corner roundness', '${(store.cardRadius * 100).round()}%', trailing: SizedBox(width: 150, child: Slider(value: store.cardRadius, min: .65, max: 1.35, onChanged: store.setCardRadius))),
          const Divider(height: 1, color: Colors.white10),
          _tile(Icons.view_agenda_rounded, 'Compact song rows', 'Fit more songs on screen', trailing: Switch(value: store.compactRows, onChanged: store.setCompactRows)),
          const Divider(height: 1, color: Colors.white10),
          _tile(Icons.album_rounded, 'Floating cover player', 'Cover in the middle, mode pills on top', trailing: Switch(value: store.floatingPlayer, onChanged: store.setFloatingPlayer)),
          const Divider(height: 1, color: Colors.white10),
          _tile(Icons.image_rounded, 'Show artwork in song lists', 'Use album/song artwork beside every track', trailing: Switch(value: store.showArtworkInLists, onChanged: store.setShowArtworkInLists)),
        ])),

        _section('LIBRARY & PLAYBACK', Column(children: [
          _tile(Icons.folder_rounded, 'Local music', '${store.songs.length} songs · rescan device', onTap: () async { await store.scanLocalMusic(); toast('Library updated'); }),
          const Divider(height: 1, color: Colors.white10),
          _tile(Icons.shuffle_rounded, 'Shuffle', store.shuffle ? 'On' : 'Off', trailing: Switch(value: store.shuffle, onChanged: (_) => store.toggleShuffle())),
          const Divider(height: 1, color: Colors.white10),
          _tile(Icons.repeat_rounded, 'Repeat', store.repeat ? 'On' : 'Off', trailing: Switch(value: store.repeat, onChanged: (_) => store.toggleRepeat())),
        ])),

        _section('RESET', Column(children: [
          _tile(Icons.restart_alt_rounded, 'Reset appearance', 'Restore the default Virgo look', onTap: () => showDialog<void>(
            context: context,
            builder: (d) => AlertDialog(
              backgroundColor: panel,
              title: const Text('Reset appearance?'),
              content: const Text('Your playback library, likes and playlists will stay untouched.'),
              actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')), FilledButton(onPressed: () { store.resetAppearance(); Navigator.pop(d); }, child: const Text('Reset'))],
            ),
          )),
        ])),

        Center(child: Text('Virgo Music V6 · Appearance settings do not change playback animations', style: const TextStyle(fontSize: 11, color: muted))),
      ],
    );
  });
}

// ───────────────────────── Detail pages ─────────────────────────
class SongListPage extends StatelessWidget {
  final MusicStore store;
  final String title;
  final List<Song> Function(MusicStore) source;
  const SongListPage({super.key, required this.store, required this.title, required this.source});

  @override
  Widget build(BuildContext context) => _R(store, (ctx) {
        final list = source(store);
        return Scaffold(
          backgroundColor: bg,
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(children: [
                  _circleBtn(Icons.arrow_back_rounded, () => Navigator.pop(ctx)),
                  const SizedBox(width: 14),
                  Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600))),
                ]),
              ),
              if (list.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(children: [
                    _pillBtn(Icons.shuffle_rounded, 'Shuffle', () => store.shuffleAll(list)),
                    const SizedBox(width: 8),
                    _pillBtn(Icons.play_arrow_rounded, 'Play', () => store.playQueue(list, 0)),
                  ]),
                ),
              Expanded(
                child: list.isEmpty
                    ? const Center(child: Text('Nothing here yet', style: TextStyle(color: muted)))
                    : ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 180),
                        itemCount: list.length,
                        itemBuilder: (_, i) => SongRow(song: list[i], store: store, queue: list),
                      ),
              ),
            ]),
          ),
        );
      });
}

class AlbumsPage extends StatelessWidget {
  final MusicStore store;
  const AlbumsPage({super.key, required this.store});
  @override
  Widget build(BuildContext context) => _R(store, (ctx) {
        final reps = store.albumReps;
        return Scaffold(
          backgroundColor: bg,
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(children: [_circleBtn(Icons.arrow_back_rounded, () => Navigator.pop(ctx)), const SizedBox(width: 14), const Text('Albums', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600))]),
              ),
              Expanded(
                child: GridView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 180),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: .82),
                  itemCount: reps.length,
                  itemBuilder: (_, i) => _PressScale(
                    onTap: () => Navigator.of(ctx).push(_slideRoute(AlbumPage(store: store, album: reps[i].album))),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      AspectRatio(aspectRatio: 1, child: LayoutBuilder(builder: (_, c) => _art(reps[i], c.maxWidth, 20))),
                      const SizedBox(height: 6),
                      Text(reps[i].album, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      Text(reps[i].primaryArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: muted)),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        );
      });
}

class ArtistsPage extends StatelessWidget {
  final MusicStore store;
  const ArtistsPage({super.key, required this.store});
  @override
  Widget build(BuildContext context) => _R(store, (ctx) {
        final names = store.artistNames;
        return Scaffold(
          backgroundColor: bg,
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(children: [_circleBtn(Icons.arrow_back_rounded, () => Navigator.pop(ctx)), const SizedBox(width: 14), const Text('Artists', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600))]),
              ),
              Expanded(
                child: GridView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 180),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: .9),
                  itemCount: names.length,
                  itemBuilder: (_, i) {
                    final rep = store.artistSongs(names[i]).first;
                    return _PressScale(
                      onTap: () => Navigator.of(ctx).push(_slideRoute(ArtistPage(store: store, artist: names[i]))),
                      child: Column(children: [
                        Expanded(child: AspectRatio(aspectRatio: 1, child: ClipOval(child: LayoutBuilder(builder: (_, c) => _art(rep, c.maxWidth, 0))))),
                        const SizedBox(height: 6),
                        Text(names[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      ]),
                    );
                  },
                ),
              ),
            ]),
          ),
        );
      });
}

class PlaylistsPage extends StatelessWidget {
  final MusicStore store;
  const PlaylistsPage({super.key, required this.store});
  @override
  Widget build(BuildContext context) => _R(store, (ctx) {
        final names = store.playlists.keys.toList();
        return Scaffold(
          backgroundColor: bg,
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(children: [_circleBtn(Icons.arrow_back_rounded, () => Navigator.pop(ctx)), const SizedBox(width: 14), const Text('Playlists', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600))]),
              ),
              Expanded(
                child: names.isEmpty
                    ? const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('No playlists yet.\nUse “Save queue as playlist” from any song menu.', textAlign: TextAlign.center, style: TextStyle(color: muted))))
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 180),
                        itemCount: names.length,
                        itemBuilder: (_, i) => _entityRow(
                          Container(width: 46, height: 46, decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(uiRadius(10))), child: Icon(Icons.queue_music_rounded, color: accent)),
                          names[i],
                          '${store.playlists[names[i]]!.length} songs',
                          () => Navigator.of(ctx).push(_slideRoute(SongListPage(store: store, title: names[i], source: (st) => st.playlistSongs(names[i])))),
                        ),
                      ),
              ),
            ]),
          ),
        );
      });
}

class ArtistPage extends StatelessWidget {
  final MusicStore store;
  final String artist;
  const ArtistPage({super.key, required this.store, required this.artist});

  @override
  Widget build(BuildContext context) => _R(store, (ctx) {
        final list = store.artistSongs(artist);
        if (list.isEmpty) return Scaffold(backgroundColor: bg, body: const Center(child: Text('Artist not found')));
        final hero = list.first;
        final albums = list.map((s) => s.album).toSet().map((a) => store.albumSongs(a).first).toList();
        final top = list.take(8).toList();
        return Scaffold(
          backgroundColor: bg,
          body: ListView(physics: const BouncingScrollPhysics(), padding: const EdgeInsets.only(bottom: 180), children: [
            SafeArea(
              bottom: false,
              child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Row(children: [_circleBtn(Icons.arrow_back_rounded, () => Navigator.pop(ctx))])),
            ),
            const SizedBox(height: 8),
            Center(child: ClipOval(child: _art(hero, 150, 0))),
            const SizedBox(height: 14),
            Center(child: Text(artist, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600))),
            const SizedBox(height: 2),
            Center(child: Text('${list.length} songs · ${albums.length} albums', style: const TextStyle(fontSize: 13, color: muted))),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _pillBtn(Icons.shuffle_rounded, 'Shuffle', () => store.shuffleAll(list)),
              const SizedBox(width: 8),
              _pillBtn(Icons.play_arrow_rounded, 'Play', () => store.playQueue(list, 0)),
            ]),
            const SizedBox(height: 20),
            _heading('Top songs'),
            ...top.map((s) => SongRow(song: s, store: store, queue: list)),
            const SizedBox(height: 22),
            _rail(ctx, store, 'Albums', albums),
          ]),
        );
      });
}

// Album page — follows the "Innerlight EP" mockup.
class AlbumPage extends StatelessWidget {
  final MusicStore store;
  final String album;
  final String? heroTag;
  const AlbumPage({super.key, required this.store, required this.album, this.heroTag});

  @override
  Widget build(BuildContext context) => _R(store, (ctx) {
        final list = store.albumSongs(album);
        if (list.isEmpty) return Scaffold(backgroundColor: bg, body: const Center(child: Text('Album not found')));
        final hero = list.first;
        final saved = store.savedAlbums.contains(album);
        final w = MediaQuery.sizeOf(ctx).width;
        final artSize = w * .68;
        final Widget cover = ClipRRect(borderRadius: BorderRadius.circular(uiRadius(22)), child: _art(hero, artSize, 0));
        final meta = [if (hero.year != null) hero.year!, '${list.length} songs'].join(' · ');
        return Scaffold(
          backgroundColor: bg,
          body: ListView(physics: const BouncingScrollPhysics(), padding: const EdgeInsets.only(bottom: 190), children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(children: [
                  _circleBtn(Icons.arrow_back_rounded, () => Navigator.pop(ctx)),
                  const Spacer(),
                  _circleBtn(Icons.share_rounded, () => toast('Sharing is not available offline')),
                ]),
              ),
            ),
            const SizedBox(height: 4),
            Center(child: heroTag != null ? Hero(tag: heroTag!, child: cover) : cover),
            const SizedBox(height: 22),
            Center(child: Text(album, textAlign: TextAlign.center, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w400))),
            const SizedBox(height: 6),
            Center(child: Text(hero.primaryArtist, style: const TextStyle(fontSize: 21))),
            const SizedBox(height: 8),
            Center(child: Text(meta, style: const TextStyle(fontSize: 13, color: muted))),
            const SizedBox(height: 22),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: SizedBox(
                height: 56,
                child: Row(children: [
                  _PressScale(
                    onTap: () => store.shuffleAll(list),
                    child: Container(
                      width: 76,
                      decoration: BoxDecoration(color: panel2, borderRadius: const BorderRadius.horizontal(left: Radius.circular(28), right: Radius.circular(6))),
                      child: const Icon(Icons.shuffle_rounded, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: _PressScale(
                      onTap: () => store.playQueue(list, 0),
                      child: Container(
                        decoration: BoxDecoration(color: Color.lerp(accent, Colors.white, .75), borderRadius: BorderRadius.circular(uiRadius(6))),
                        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.play_arrow_rounded, color: Color(0xFF1D1B20)),
                          SizedBox(width: 8),
                          Text('Play', style: TextStyle(color: Color(0xFF1D1B20), fontSize: 17, fontWeight: FontWeight.w500)),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  _PressScale(
                    onTap: () => store.toggleSavedAlbum(album),
                    child: Container(
                      width: 76,
                      decoration: BoxDecoration(color: saved ? accent.withOpacity(.6) : tonal, borderRadius: const BorderRadius.horizontal(left: Radius.circular(6), right: Radius.circular(28))),
                      child: Icon(saved ? Icons.check_rounded : Icons.add_rounded, color: Colors.white),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 18),
            for (var i = 0; i < list.length; i++) SongRow(song: list[i], store: store, queue: list, number: i + 1, roomy: true),
          ]),
        );
      });
}

// ───────────────────────── Now Playing (mockup layout) ─────────────────────────
class NowPlayingPage extends StatelessWidget {
  final MusicStore store;
  const NowPlayingPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final song = store.current;
        if (song == null) return Scaffold(backgroundColor: bg);
        final liked = store.liked.contains(song.id);
        if (store.floatingPlayer) return _floating(ctx, song, liked);
        final h = MediaQuery.sizeOf(ctx).height;
        final next = store.upNext;
        return Scaffold(
          backgroundColor: bg,
          body: Stack(children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: h * .58,
              child: Hero(
                tag: 'player-art',
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 420),
                  layoutBuilder: (cur, prev) => Stack(fit: StackFit.expand, children: [...prev, if (cur != null) cur]),
                  child: KeyedSubtree(key: ValueKey('bg-${song.id}'), child: _art(song, double.infinity, 0, height: h * .58)),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [const Color(0x44000000), Colors.transparent, bg.withOpacity(.88), bg],
                    stops: const [0, .28, .56, .72],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(children: [
                  Row(children: [
                    _circleBtn(Icons.keyboard_arrow_down_rounded, () => Navigator.pop(ctx)),
                    const Spacer(),
                    _circleBtn(Icons.more_vert_rounded, () => _showSongMenu(ctx, song, store, player: true)),
                  ]),
                  const Spacer(),
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 230),
                        transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween<Offset>(begin: const Offset(0, .12), end: Offset.zero).animate(a), child: c)),
                        child: SizedBox(
                          key: ValueKey('t-${song.id}'),
                          width: double.infinity,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500)),
                            const SizedBox(height: 4),
                            Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15.5, color: Color.lerp(muted, accent, .22))),
                          ]),
                        ),
                      ),
                    ),
                    _PressScale(
                      onTap: () => store.toggleLike(song),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: AnimatedScale(
                          scale: liked ? 1.12 : 1,
                          duration: const Duration(milliseconds: 160),
                          child: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: accent, size: 28),
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  _WaveProgress(store: store),
                  const SizedBox(height: 12),
                  _Transport(store: store),
                  const SizedBox(height: 18),
                  Row(children: [
                    _PressScale(onTap: () => _showSheet(ctx, (c) => QueueSheet(store: store)), child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.queue_music_rounded, size: 28))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _showSheet(ctx, (c) => QueueSheet(store: store)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('Up next', style: TextStyle(fontSize: 12, color: muted)),
                          Text(next?.title ?? 'End of queue', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
                        ]),
                      ),
                    ),
                    _PressScale(onTap: () => toast('Lyrics are not available offline'), child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.lyrics_outlined, size: 26))),
                  ]),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }

  // Layout of the "NO / Riserayss" mockup: lyrics icon + shuffle/repeat/queue pill + heart on top,
  // floating cover, left-aligned title, wavy progress, one connected prev / play / next pill.
  Widget _floating(BuildContext ctx, Song song, bool liked) {
    final size = MediaQuery.sizeOf(ctx);
    final artW = size.width - 56;
    final glow = KeyedSubtree(
      key: ValueKey('glow-${song.id}'),
      child: Opacity(
        opacity: .34,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 42, sigmaY: 42),
          child: _art(song, double.infinity, 0, height: size.height),
        ),
      ),
    );
    return Scaffold(
      backgroundColor: bg,
      body: Stack(children: [
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            layoutBuilder: (cur, prev) => Stack(fit: StackFit.expand, children: [...prev, if (cur != null) cur]),
            child: glow,
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [bg, bg.withOpacity(.88), bg.withOpacity(.40), bg.withOpacity(.62)],
                stops: const [0, .40, .78, 1],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Row(children: [
                SizedBox(
                  width: 52,
                  child: _PressScale(
                    onTap: () => toast('Lyrics are not available offline'),
                    child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.lyrics_outlined, size: 26)),
                  ),
                ),
                const Spacer(),
                _ModeGroup(store: store, onQueue: () => _showSheet(ctx, (c) => QueueSheet(store: store))),
                const Spacer(),
                SizedBox(
                  width: 52,
                  child: _PressScale(
                    onTap: () => store.toggleLike(song),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: AnimatedScale(
                        scale: liked ? 1.12 : 1,
                        duration: const Duration(milliseconds: 160),
                        child: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: accent, size: 28),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: Center(
                child: Hero(
                  tag: 'player-art',
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    layoutBuilder: (cur, prev) => Stack(alignment: Alignment.center, children: [...prev, if (cur != null) cur]),
                    child: KeyedSubtree(key: ValueKey('art-${song.id}'), child: _art(song, artW, uiRadius(10))),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 230),
                transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween<Offset>(begin: const Offset(0, .12), end: Offset.zero).animate(a), child: c)),
                child: SizedBox(
                  key: ValueKey('t-${song.id}'),
                  width: double.infinity,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w400)),
                    const SizedBox(height: 4),
                    Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, color: Color.lerp(muted, Colors.white, .35))),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: _WaveProgress(store: store, big: true)),
            const SizedBox(height: 14),
            FractionallySizedBox(widthFactor: .62, child: _PillTransport(store: store)),
            const SizedBox(height: 22),
          ]),
        ),
      ]),
    );
  }
}

class _ModeGroup extends StatelessWidget {
  final MusicStore store;
  final VoidCallback onQueue;
  const _ModeGroup({required this.store, required this.onQueue});

  Widget _seg(IconData icon, bool on, VoidCallback onTap, BorderRadius idle) => _PressScale(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: 52,
          height: 44,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(
            color: on ? Color.lerp(accent, Colors.white, .35) : Color.lerp(panel2, Colors.white, .07),
            borderRadius: on ? BorderRadius.circular(22) : idle,
          ),
          child: Icon(icon, size: 21, color: on ? const Color(0xFF14171C) : Colors.white),
        ),
      );

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: Colors.black.withOpacity(.38), borderRadius: BorderRadius.circular(28)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _seg(Icons.shuffle_rounded, store.shuffle, store.toggleShuffle, const BorderRadius.horizontal(left: Radius.circular(22), right: Radius.circular(8))),
          _seg(Icons.repeat_rounded, store.repeat, store.toggleRepeat, BorderRadius.circular(8)),
          _seg(Icons.queue_music_rounded, false, onQueue, const BorderRadius.horizontal(left: Radius.circular(8), right: Radius.circular(22))),
        ]),
      );
}

class _PillTransport extends StatelessWidget {
  final MusicStore store;
  const _PillTransport({required this.store});

  Widget _side(IconData icon, VoidCallback onTap, BorderRadius r) => Expanded(
        flex: 5,
        child: _PressScale(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(color: Color.lerp(panel2, Colors.white, .07), borderRadius: r),
            child: Icon(icon, size: 28, color: Colors.white),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Container(
        height: 68,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: Colors.black.withOpacity(.38), borderRadius: BorderRadius.circular(34)),
        child: Row(children: [
          _side(Icons.skip_previous_rounded, store.skipPrev, const BorderRadius.horizontal(left: Radius.circular(30), right: Radius.circular(8))),
          const SizedBox(width: 3),
          Expanded(
            flex: 8,
            child: _PressScale(
              onTap: store.toggle,
              child: Container(
                decoration: BoxDecoration(color: Color.lerp(accent, Colors.white, .35), borderRadius: BorderRadius.circular(30)),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
                  child: Icon(store.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(store.playing), color: const Color(0xFF14171C), size: 32),
                ),
              ),
            ),
          ),
          const SizedBox(width: 3),
          _side(Icons.skip_next_rounded, store.skipNext, const BorderRadius.horizontal(left: Radius.circular(8), right: Radius.circular(30))),
        ]),
      );
}

class _Transport extends StatelessWidget {
  final MusicStore store;
  const _Transport({required this.store});

  Widget _side(IconData icon, VoidCallback onTap) => Expanded(
        flex: 3,
        child: _PressScale(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(color: tonal, borderRadius: BorderRadius.circular(uiRadius(32))),
            child: Icon(icon, size: 28, color: Colors.white),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 78,
        child: Row(children: [
          _side(Icons.skip_previous_rounded, store.skipPrev),
          const SizedBox(width: 10),
          Expanded(
            flex: 5,
            child: _PressScale(
              onTap: store.toggle,
              child: Container(
                decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(uiRadius(32))),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
                  child: Icon(store.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(store.playing), color: onAccent, size: 34),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _side(Icons.skip_next_rounded, store.skipNext),
        ]),
      );
}

class _WaveProgress extends StatefulWidget {
  final MusicStore store;
  final bool big;
  const _WaveProgress({required this.store, this.big = false});
  @override
  State<_WaveProgress> createState() => _WaveProgressState();
}

class _WaveProgressState extends State<_WaveProgress> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
  MusicStore get s => widget.store;

  void _sync() {
    if (s.playing && !_c.isAnimating) _c.repeat();
    if (!s.playing && _c.isAnimating) _c.stop();
  }

  @override
  void initState() {
    super.initState();
    s.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    s.removeListener(_sync);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: s.progressN,
        builder: (_, p, __) {
          final d = s.dur;
          final cur = Duration(milliseconds: (d.inMilliseconds * p).round());
          const t = TextStyle(fontSize: 12, color: muted);
          return Column(children: [
            LayoutBuilder(builder: (_, box) {
              final w = box.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (e) => s.seek(e.localPosition.dx / w),
                onHorizontalDragUpdate: (e) => s.seek(e.localPosition.dx / w),
                child: RepaintBoundary(
                  child: AnimatedBuilder(animation: _c, builder: (_, __) => CustomPaint(size: Size(w, widget.big ? 46 : 36), painter: widget.big ? _WavePainter(p, _c.value, Color.lerp(accent, Colors.white, .35)!, amp: 5.5, stroke: 4.5, wavelength: 42, thumbHeight: 42) : _WavePainter(p, _c.value, accent))),
                ),
              );
            }),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_fmt(cur), style: t), Text('-${_fmt(d - cur)}', style: t)]),
          ]);
        },
      );
}

class _WavePainter extends CustomPainter {
  final double v, phase, amp, stroke, wavelength, thumbHeight;
  final Color color;
  _WavePainter(this.v, this.phase, this.color, {this.amp = 4.5, this.stroke = 4, this.wavelength = 28, this.thumbHeight = 28});

  @override
  void paint(Canvas c, Size s) {
    final cy = s.height / 2;
    final x = (s.width * v).clamp(0.0, s.width).toDouble();
    final track = Paint()
      ..color = Colors.white38
      ..strokeWidth = stroke * .65
      ..strokeCap = StrokeCap.round;
    c.drawLine(Offset(math.min(x + (thumbHeight > 0 ? 6 : 0), s.width), cy), Offset(s.width - 2, cy), track);
    c.drawCircle(Offset(s.width - 2, cy), stroke * .75, Paint()..color = color);
    final path = Path()..moveTo(0, cy);
    for (double dx = 0; dx <= x; dx += 2) {
      path.lineTo(dx, cy + amp * math.sin((dx / wavelength - phase) * 2 * math.pi));
    }
    c.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = stroke..strokeCap = StrokeCap.round);
    if (thumbHeight > 0) {
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, cy), width: 4, height: thumbHeight), const Radius.circular(2)), Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_WavePainter o) => o.v != v || o.phase != phase || o.color != color;
}

// ───────────────────────── Queue sheet ─────────────────────────
class QueueSheet extends StatelessWidget {
  final MusicStore store;
  const QueueSheet({super.key, required this.store});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (ctx, _) {
          final cur = store.current;
          return SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .70,
            child: Column(children: [
              const SizedBox(height: 10),
              Container(width: 38, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(uiRadius(8)))),
              const SizedBox(height: 12),
              const Text('Playing from artist', style: TextStyle(fontSize: 11, color: muted)),
              Text('${cur?.primaryArtist ?? ''} · ${_left(store)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _pillBtn(Icons.shuffle_rounded, 'Shuffle', store.shuffleUpcoming),
                const SizedBox(width: 8),
                _pillBtn(Icons.clear_all_rounded, 'Clear', store.clearUpcoming),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: store.queue.length,
                  itemBuilder: (_, i) {
                    final s = store.queue[i];
                    final active = i == store.qIndex;
                    return _PressScale(
                      onTap: () => store.jumpTo(i),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(color: active ? tonal.withOpacity(.85) : Colors.transparent, borderRadius: BorderRadius.circular(uiRadius(14))),
                        child: Row(children: [
                          _art(s, 44, 10),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: active ? FontWeight.w600 : FontWeight.w500)),
                              Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: muted)),
                            ]),
                          ),
                          Text(_fmt(s.duration), style: const TextStyle(fontSize: 12, color: muted)),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            ]),
          );
        },
      );
}
