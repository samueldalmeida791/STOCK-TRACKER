import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fl_chart/fl_chart.dart';

// ---------- MODELS ----------
class StockQuote {
  final String symbol;
  final double price;
  final double change;
  final double changePercent;
  final String currency;

  StockQuote({
    required this.symbol,
    required this.price,
    required this.change,
    required this.changePercent,
    required this.currency,
  });
}

class PriceAlert {
  final double? below; // trigger when price <= below
  final double? above; // trigger when price >= above
  const PriceAlert({this.below, this.above});

  Map<String, dynamic> toJson() => {'below': below, 'above': above};
  factory PriceAlert.fromJson(Map<String, dynamic> j) =>
      PriceAlert(below: (j['below'] as num?)?.toDouble(), above: (j['above'] as num?)?.toDouble());
}

// ---------- SERVICES ----------
class YahooApi {
  static Future<StockQuote?> fetchQuote(String symbol) async {
    final url = Uri.parse('https://query1.finance.yahoo.com/v7/finance/quote?symbols=$symbol');
    final r = await http.get(url);
    if (r.statusCode != 200) return null;
    final result = jsonDecode(r.body)['quoteResponse']['result'];
    if (result is List && result.isNotEmpty) {
      final m = result[0] as Map<String, dynamic>;
      final price = (m['regularMarketPrice'] as num?)?.toDouble();
      final change = (m['regularMarketChange'] as num?)?.toDouble() ?? 0.0;
      final changePct = (m['regularMarketChangePercent'] as num?)?.toDouble() ?? 0.0;
      final currency = (m['currency'] as String?) ?? '';
      if (price == null) return null;
      return StockQuote(
        symbol: (m['symbol'] as String).toUpperCase(),
        price: price,
        change: change,
        changePercent: changePct,
        currency: currency,
      );
    }
    return null;
  }

  // Returns (timestamps, closes) for intraday chart (1 day, 5m interval)
  static Future<List<FlSpot>> fetchIntradaySpots(String symbol) async {
    final url = Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/$symbol?range=1d&interval=5m');
    final r = await http.get(url);
    if (r.statusCode != 200) return [];
    final j = jsonDecode(r.body);
    final chart = j['chart'];
    if (chart == null || chart['result'] == null) return [];
    final res = chart['result'][0];
    final List ts = (res['timestamp'] as List?) ?? [];
    final List closes = (res['indicators']?['quote']?[0]?['close'] as List?) ?? [];
    final List<FlSpot> spots = [];
    for (int i = 0; i < ts.length && i < closes.length; i++) {
      final c = closes[i];
      if (c == null) continue;
      // use index for x to keep it simple/monotonic
      spots.add(FlSpot(i.toDouble(), (c as num).toDouble()));
    }
    return spots;
  }
}

class Notifier {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    final init = InitializationSettings(android: android, iOS: ios);
    await _plugin.initialize(init);
  }

  static Future<void> notify(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
      'stock_alerts',
      'Stock Alerts',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
    );
    const iosDetails = DarwinNotificationDetails(presentSound: true);
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _plugin.show(DateTime.now().millisecondsSinceEpoch ~/ 1000, title, body, details);
  }
}

// ---------- STATE ----------
class WatchlistState extends ChangeNotifier {
  WatchlistState() {
    _load();
    _startPolling();
  }

  final List<String> _tickers = [];
  final Map<String, StockQuote> _quotes = {};
  final Map<String, PriceAlert> _alerts = {};
  Timer? _poll;

  List<String> get tickers => List.unmodifiable(_tickers);
  StockQuote? quoteOf(String t) => _quotes[t.toUpperCase()];
  PriceAlert? alertOf(String t) => _alerts[t.toUpperCase()];

  Future<void> addTicker(String t) async {
    final sym = t.trim().toUpperCase();
    if (sym.isEmpty) return;
    if (!_tickers.contains(sym)) {
      _tickers.add(sym);
      notifyListeners();
      await _save();
      await refresh([sym]);
    }
  }

  Future<void> removeTicker(String t) async {
    _tickers.remove(t);
    _quotes.remove(t);
    _alerts.remove(t);
    notifyListeners();
    await _save();
  }

  Future<void> setAlert(String t, PriceAlert? a) async {
    if (a == null || (a.above == null && a.below == null)) {
      _alerts.remove(t);
    } else {
      _alerts[t] = a;
    }
    notifyListeners();
    await _save();
  }

  Future<void> refresh([List<String>? only]) async {
    final list = (only ?? _tickers).toList();
    for (final s in list) {
      final q = await YahooApi.fetchQuote(s);
      if (q != null) {
        _quotes[s] = q;
        _checkAlert(q);
      }
    }
    notifyListeners();
  }

  void _checkAlert(StockQuote q) {
    final a = _alerts[q.symbol];
    if (a == null) return;
    final p = q.price;
    if (a.above != null && p >= a.above!) {
      Notifier.notify('${q.symbol} crossed ↑ ${a.above}', 'Now ${p.toStringAsFixed(2)} ${q.currency}');
      _alerts.remove(q.symbol); // auto-clear to avoid spamming; comment this if you prefer persistent
    } else if (a.below != null && p <= a.below!) {
      Notifier.notify('${q.symbol} crossed ↓ ${a.below}', 'Now ${p.toStringAsFixed(2)} ${q.currency}');
      _alerts.remove(q.symbol);
    }
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('tickers', _tickers);
    final aJson = _alerts.map((k, v) => MapEntry(k, jsonEncode(v.toJson())));
    await sp.setString('alerts', jsonEncode(aJson));
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    _tickers.clear();
    _tickers.addAll(sp.getStringList('tickers') ?? ['AAPL', 'MSFT', 'TSLA']);
    final aStr = sp.getString('alerts');
    _alerts.clear();
    if (aStr != null) {
      final Map<String, dynamic> map = jsonDecode(aStr);
      map.forEach((k, v) {
        _alerts[k] = PriceAlert.fromJson(jsonDecode(v));
      });
    }
    await refresh();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}

// ---------- UI ----------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notifier.init();
  runApp(const StockApp());
}

class StockApp extends StatefulWidget {
  const StockApp({super.key});
  @override
  State<StockApp> createState() => _StockAppState();
}

class _StockAppState extends State<StockApp> {
  late final WatchlistState state;

  @override
  void initState() {
    super.initState();
    state = WatchlistState();
  }

  @override
  void dispose() {
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stock Tracker',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: WatchlistScreen(state: state),
    );
  }
}

class WatchlistScreen extends StatefulWidget {
  final WatchlistState state;
  const WatchlistScreen({super.key, required this.state});

  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  final _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final tickers = widget.state.tickers;
        return Scaffold(
          appBar: AppBar(title: const Text('Watchlist')),
          body: RefreshIndicator(
            onRefresh: () => widget.state.refresh(),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: tickers.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) return _buildAddRow(context);
                final t = tickers[i - 1];
                final q = widget.state.quoteOf(t);
                final price = q?.price.toStringAsFixed(2) ?? '—';
                final ch = q?.change ?? 0;
                final pct = q?.changePercent ?? 0;
                final isUp = ch >= 0;
                final alert = widget.state.alertOf(t);

                return Dismissible(
                  key: ValueKey(t),
                  background: Container(color: Colors.red),
                  onDismissed: (_) => widget.state.removeTicker(t),
                  child: ListTile(
                    title: Text(t, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(q == null ? 'Loading…' : '${ch.toStringAsFixed(2)} (${pct.toStringAsFixed(2)}%)'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (alert != null)
                          const Icon(Icons.notifications_active),
                        const SizedBox(width: 8),
                        Text(price, style: TextStyle(color: isUp ? Colors.green : Colors.red, fontSize: 16)),
                        IconButton(
                          icon: const Icon(Icons.notifications_none),
                          onPressed: () => _showAlertDialog(t),
                          tooltip: 'Set alert',
                        ),
                        IconButton(
                          icon: const Icon(Icons.show_chart),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => DetailScreen(symbol: t)),
                          ),
                          tooltip: 'Chart',
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildAddRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Add ticker (e.g., AAPL)',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(onPressed: _add, child: const Text('Add')),
        ],
      ),
    );
  }

  void _add() {
    final v = _controller.text.trim();
    if (v.isNotEmpty) {
      widget.state.addTicker(v);
      _controller.clear();
    }
  }

  Future<void> _showAlertDialog(String symbol) async {
    final existing = widget.state.alertOf(symbol);
    final aboveCtrl = TextEditingController(text: existing?.above?.toString() ?? '');
    final belowCtrl = TextEditingController(text: existing?.below?.toString() ?? '');

    final res = await showDialog<PriceAlert?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Alert for $symbol'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: aboveCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Notify when price ≥'),
            ),
            TextField(
              controller: belowCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Notify when price ≤'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Remove'),
          ),
          FilledButton(
            onPressed: () {
              double? above = double.tryParse(aboveCtrl.text.trim());
              double? below = double.tryParse(belowCtrl.text.trim());
              if (above == null && below == null) {
                Navigator.pop(context, null);
              } else {
                Navigator.pop(context, PriceAlert(above: above, below: below));
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    await widget.state.setAlert(symbol, res);
  }
}

class DetailScreen extends StatefulWidget {
  final String symbol;
  const DetailScreen({super.key, required this.symbol});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  List<FlSpot> spots = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    spots = await YahooApi.fetchIntradaySpots(widget.symbol);
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.symbol} • 1D')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : spots.isEmpty
              ? const Center(child: Text('No chart data'))
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: spots.last.x,
                      lineBarsData: [
                        LineChartBarData(
                          isCurved: true,
                          preventCurveOverShooting: true,
                          spots: spots,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(show: true, applyCutOffY: false),
                          isStrokeCapRound: true,
                          barWidth: 2,
                        ),
                      ],
                      gridData: const FlGridData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      borderData: FlBorderData(show: false),
                    ),
                  ),
                ),
    );
  }
}
