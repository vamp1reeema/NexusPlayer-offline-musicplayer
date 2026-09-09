import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _bg = Color(0xFF100D0D);
const _panel = Color(0xFF1C1517);
const _panelSoft = Color(0xFF241A1C);
const _line = Color(0xFF38292C);
const _text = Color(0xFFEEE9E2);
const _muted = Color(0xFF796B6B);
const _bloodBright = Color(0xFFD15A55);
const _silver = Color(0xFFCBC9C8);

class EqualizerEngine {
  static const _channel = MethodChannel('nexus_player/equalizer');
  static int? _sessionId;

  static Future<Map<String, dynamic>?> attach(int sessionId) async {
    if (sessionId == 0) return null;
    _sessionId = sessionId;
    try {
      final raw = await _channel.invokeMethod<Map>('attach', {
        'sessionId': sessionId,
      });
      return raw?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> getBands() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getBands');
      return raw?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  static Future<void> setBand(int index, double levelDb) async {
    try {
      await _channel.invokeMethod('setBand', {
        'index': index,
        'level': levelDb,
      });
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> setPreset(String name) async {
    try {
      final raw = await _channel.invokeMethod<Map>('setPreset', {'name': name});
      return raw?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  /// strength 0..1000
  static Future<void> setBassBoost(int strength) async {
    try {
      await _channel.invokeMethod('setBassBoost', {'strength': strength});
    } catch (_) {}
  }

  /// strength 0..1000
  static Future<void> setVirtualizer(int strength) async {
    try {
      await _channel.invokeMethod('setVirtualizer', {'strength': strength});
    } catch (_) {}
  }

  /// mB 0..1000 (millibels gain)
  static Future<void> setLoudness(int mB) async {
    try {
      await _channel.invokeMethod('setLoudness', {'mB': mB});
    } catch (_) {}
  }

  static int? get sessionId => _sessionId;
}

class EqualizerScreen extends StatefulWidget {
  const EqualizerScreen({super.key});

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  bool enabled = true;
  bool supported = false;
  List<Map<String, dynamic>> bands = [];
  double minLevel = -12;
  double maxLevel = 12;
  String preset = 'Flat';
  double bass = 0; // 0..1
  double virtual = 1; // 0..1 display as %
  double loudness = 0; // 0..1

  static const presets = [
    'Flat',
    'Acoustic',
    'Bass Booster',
    'Bass Reducer',
    'Classical',
    'Dance',
    'Electronic',
    'Hip Hop',
    'Jazz',
    'Pop',
    'Rock',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await EqualizerEngine.getBands();
    if (!mounted) return;
    _applyInfo(info);
  }

  void _applyInfo(Map<String, dynamic>? info) {
    if (info == null) {
      setState(() => supported = false);
      return;
    }
    final rawBands = info['bands'];
    final list = <Map<String, dynamic>>[];
    if (rawBands is List) {
      for (final b in rawBands) {
        if (b is Map) {
          list.add(b.map((k, v) => MapEntry(k.toString(), v)));
        }
      }
    }
    setState(() {
      supported = info['supported'] == true;
      bands = list;
      minLevel = (info['minLevel'] as num?)?.toDouble() ?? -12;
      maxLevel = (info['maxLevel'] as num?)?.toDouble() ?? 12;
    });
  }

  String _freqLabel(num hz) {
    if (hz >= 1000) {
      final k = hz / 1000;
      return k == k.roundToDouble() ? '${k.toInt()}k' : '${k.toStringAsFixed(1)}k';
    }
    return '${hz.round()}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded, color: _text),
                  ),
                  const Spacer(),
                  const Icon(Icons.graphic_eq, color: _muted, size: 20),
                  const SizedBox(width: 10),
                  Switch(
                    value: enabled,
                    activeColor: _silver,
                    activeTrackColor: _bloodBright,
                    onChanged: (v) async {
                      setState(() => enabled = v);
                      await EqualizerEngine.setEnabled(v);
                    },
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(
                'Эквалайзер',
                style: TextStyle(
                  color: _text,
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                supported
                    ? '${bands.length} полос  ·  ${minLevel.toStringAsFixed(0)}…${maxLevel.toStringAsFixed(0)} dB'
                    : 'Системный эквалайзер недоступен на этом устройстве',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  if (supported && bands.isNotEmpty)
                    Container(
                      height: 220,
                      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                      decoration: BoxDecoration(
                        color: _panel,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _line),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final b in bands)
                            Expanded(
                              child: _BandSlider(
                                freq: _freqLabel(b['freq'] as num? ?? 0),
                                value: (b['level'] as num?)?.toDouble() ?? 0,
                                min: minLevel,
                                max: maxLevel,
                                enabled: enabled,
                                onChanged: (v) async {
                                  final i = b['index'] as int? ?? 0;
                                  setState(() {
                                    b['level'] = v;
                                  });
                                  await EqualizerEngine.setBand(i, v);
                                  setState(() => preset = 'Custom');
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final p in presets)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(p),
                              selected: preset == p,
                              selectedColor: _silver,
                              labelStyle: TextStyle(
                                color: preset == p
                                    ? const Color(0xFF1B1617)
                                    : _text,
                                fontSize: 13,
                              ),
                              backgroundColor: _panelSoft,
                              side: BorderSide(
                                color: preset == p ? _silver : _line,
                              ),
                              onSelected: enabled
                                  ? (_) async {
                                      setState(() => preset = p);
                                      final info =
                                          await EqualizerEngine.setPreset(p);
                                      if (mounted) _applyInfo(info);
                                    }
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _EffectCard(
                    title: 'Усиление басов',
                    subtitle:
                        'Поднимает нижние две октавы, не затрагивая остальную часть кривой.',
                    trailing: bass <= 0.01 ? 'ВЫКЛ.' : '${(bass * 100).round()}%',
                    value: bass,
                    onChanged: enabled
                        ? (v) async {
                            setState(() => bass = v);
                            await EqualizerEngine.setBassBoost(
                              (v * 1000).round(),
                            );
                          }
                        : null,
                  ),
                  const SizedBox(height: 12),
                  _EffectCard(
                    title: 'Объёмный звук',
                    subtitle:
                        'Расширяет стереокартину, имитируя пространственную глубину.',
                    trailing: '${(virtual * 100).round()}%',
                    value: virtual,
                    onChanged: enabled
                        ? (v) async {
                            setState(() => virtual = v);
                            await EqualizerEngine.setVirtualizer(
                              (v * 1000).round(),
                            );
                          }
                        : null,
                  ),
                  const SizedBox(height: 12),
                  _EffectCard(
                    title: 'Усиление громкости',
                    subtitle:
                        'Усиливает воспроизведение выше единичного уровня. При высоких значениях возможны искажения.',
                    trailing:
                        loudness <= 0.01 ? 'ВЫКЛ.' : '${(loudness * 100).round()}%',
                    value: loudness,
                    onChanged: enabled
                        ? (v) async {
                            setState(() => loudness = v);
                            await EqualizerEngine.setLoudness(
                              (v * 1000).round(),
                            );
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BandSlider extends StatelessWidget {
  const _BandSlider({
    required this.freq,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final String freq;
  final double value;
  final double min;
  final double max;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: RotatedBox(
            quarterTurns: -1,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: _silver,
                inactiveTrackColor: _line,
                thumbColor: _silver,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(freq, style: const TextStyle(color: _muted, fontSize: 9)),
        Text(
          value.round().toString(),
          style: const TextStyle(color: _muted, fontSize: 9),
        ),
      ],
    );
  }
}

class _EffectCard extends StatelessWidget {
  const _EffectCard({
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final String trailing;
  final double value;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(trailing, style: const TextStyle(color: _muted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: const TextStyle(color: _muted, fontSize: 12)),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: _silver,
              inactiveTrackColor: _line,
              thumbColor: _silver,
              trackHeight: 3,
            ),
            child: Slider(
              value: value.clamp(0.0, 1.0),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}


/// Real-time audio energy from Android Visualizer (0.0 … 1.0).
class AudioVisualizer {
  static const _channel = EventChannel('nexus_player/visualizer');
  static Stream<double>? _stream;

  static Stream<double> get stream {
    _stream ??= _channel.receiveBroadcastStream().map((e) {
      if (e is num) return e.toDouble().clamp(0.0, 1.0);
      return 0.0;
    });
    return _stream!;
  }
}
