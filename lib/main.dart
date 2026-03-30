import "dart:async";
import "dart:convert";
import "dart:isolate";
import "dart:math";
import "package:cloud_firestore/cloud_firestore.dart";
import "package:firebase_core/firebase_core.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";

// ---------------------------------------------------------------------------
// Global log sink — collects logs for the UI
// ---------------------------------------------------------------------------

final _globalLog = <String>[];
VoidCallback? _onGlobalLog;
final _log = Logger("App");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Number of large documents to seed into Firestore.
const kDocCount = 30;

/// Approximate size of each document's base64 blob field in bytes.
/// Our production documents embed small inline images (e.g. hand-drawn
/// signatures) at ~2-5 KB each, stored as base64 PNG strings.
const kBlobBytes = 3 * 1024;

/// Number of concurrent snapshot listeners to open.
/// A typical screen in our app has 3 list tabs + 1 dashboard widget + 2-4
/// child-document streams in a detail editor = 6-10 concurrent listeners.
const kListenerCount = 8;

/// Number of status values used in whereIn filters.
const kStatusValues = 6;

// ---------------------------------------------------------------------------
// App entry point
// ---------------------------------------------------------------------------

void _appendGlobalLog(String message, {Level level = Level.INFO}) {
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  _globalLog.add("[$ts] $message");
  _log.log(level, message);
  _onGlobalLog?.call();
}

Future<void> main() async {
  // Set up console logging
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print("[${record.level.name}] ${record.loggerName}: ${record.message}");
  });

  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Capture Flutter framework errors (layout, rendering, etc.)
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        _appendGlobalLog(
          "FLUTTER ERROR: ${details.exceptionAsString()}",
          level: Level.SEVERE,
        );
      };

      // Capture uncaught async errors
      PlatformDispatcher.instance.onError = (error, stack) {
        _appendGlobalLog("PLATFORM ERROR: $error", level: Level.SEVERE);

        return false;
      };

      await Firebase.initializeApp();
      runApp(const ReproApp());
    },
    (error, stack) {
      _appendGlobalLog("ZONE ERROR: $error", level: Level.SEVERE);
    },
  );
}

class ReproApp extends StatelessWidget {
  const ReproApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Firestore 26.0.2 Performance Regression",
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      home: const ReproScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Main screen
// ---------------------------------------------------------------------------

class ReproScreen extends StatefulWidget {
  const ReproScreen({super.key});

  @override
  State<ReproScreen> createState() => _ReproScreenState();
}

class _ReproScreenState extends State<ReproScreen> {
  final _scrollController = ScrollController();
  final _listeners =
      <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];

  Isolate? _cpuIsolate;
  bool _seeded = false;
  bool _listening = false;
  bool _cpuRunning = false;
  int _snapshotCount = 0;

  // Canary writer state
  Timer? _canaryTimer;
  Timer? _canaryTimeoutTimer;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _canarySub;
  bool _canaryRunning = false;
  int _canaryWrites = 0;
  int _canaryReceived = 0;
  int _canaryMissed = 0;
  int _canaryMaxLatencyMs = 0;
  int _canaryTotalLatencyMs = 0;
  final _pendingCanaryWrites = <int, Stopwatch>{}; // seqNum → stopwatch

  CollectionReference<Map<String, dynamic>> get _collection =>
      FirebaseFirestore.instance.collection("perf_test");

  @override
  void initState() {
    super.initState();

    // Register as the listener for all global log entries (including errors
    // captured by FlutterError.onError, PlatformDispatcher.onError, and
    // runZonedGuarded).
    _onGlobalLog = _onNewLogEntry;
  }

  void _onNewLogEntry() {
    if (mounted) {
      setState(() {});
      _scrollToBottom();
    }
  }

  // -------------------------------------------------------------------------
  // Logging
  // -------------------------------------------------------------------------

  void _addLog(String message) {
    _appendGlobalLog(message);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // -------------------------------------------------------------------------
  // 1. Seed large documents
  // -------------------------------------------------------------------------

  Future<void> _seedData() async {
    _addLog(
      "Seeding $kDocCount documents (~${kBlobBytes ~/ 1024} KB blob each)...",
    );

    final rng = Random();
    final batch = FirebaseFirestore.instance.batch();

    for (var i = 0; i < kDocCount; i++) {
      final doc = _collection.doc("doc_$i");
      batch.set(doc, _buildLargeDocument(i, rng));
    }

    final sw = Stopwatch()..start();
    await batch.commit();
    sw.stop();

    _addLog("Seeded $kDocCount docs in ${sw.elapsedMilliseconds} ms");
    setState(() => _seeded = true);
  }

  /// Builds a large document (~50-100 KB) with characteristics common to
  /// real-world apps:
  ///   - 50+ top-level fields
  ///   - Deeply nested maps
  ///   - Large base64 string fields (e.g. inline image attachments)
  ///   - Arrays of reference IDs
  ///   - Multiple integer fields used in query filters
  ///   - Nullable fields
  Map<String, dynamic> _buildLargeDocument(int index, Random rng) {
    // Generate a random base64 string simulating an inline image attachment.
    final blobBytes = Uint8List(kBlobBytes);
    for (var j = 0; j < blobBytes.length; j++) {
      blobBytes[j] = rng.nextInt(256);
    }
    final blob = base64Encode(blobBytes);

    return {
      "index": index,
      "tenantId": "tenant_${index % 3}",
      "departmentId": "dept_${index % 5}",
      "teamId": "team_${index % 4}",
      "assigneeId": "user_${index % 10}",
      "creatorId": "user_${index % 8}",
      "reviewerId": "user_${index % 6}",
      "category": index % 4,
      "status": index % kStatusValues,
      "priority": index % 3,
      "dueDate": Timestamp.now(),
      "createdAt": Timestamp.now(),
      "updatedAt": Timestamp.now(),
      "deletedAt": null,
      "title": "Work item #$index — Detailed task with full context",
      "description":
          "Lorem ipsum dolor sit amet, consectetur adipiscing elit. "
              "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. " *
          5,
      "eventId": "event_${index % 20}",
      "tagId": "tag_${index % 50}",
      "templateId": "tmpl_${index % 12}",
      "groupId": "grp_${index % 8}",
      "regionId": "rgn_${index % 4}",
      "isStandalone": index % 2 == 0,
      "parentId": index % 3 == 0 ? "parent_${index ~/ 3}" : null,
      "secondaryParentId": index % 3 == 1 ? "sparent_${index ~/ 3}" : null,
      "childIds": List.generate(5, (j) => "child_${index}_$j"),
      "relatedIds": List.generate(3, (j) => "related_${index}_$j"),
      "batchId": index % 5 == 0 ? "batch_${index ~/ 5}" : null,
      // Nested map: approval (with large inline image attachment)
      "approval": {
        "reviewerId": "user_${index % 6}",
        "type": index % 3,
        "submittedAt": Timestamp.now(),
        "approvedAt": index % 4 == 0 ? Timestamp.now() : null,
        "rejectedAt": null,
        "attachmentA": blob,
        "attachmentB": blob,
        "notes":
            "Reviewer notes on the submitted work item. "
                "Detailed feedback covering multiple dimensions "
                "of quality and completeness. " *
            3,
      },
      // Nested map: scoring / metrics
      "metrics": {
        "outcome": index % 3,
        "formId": "form_${index % 5}",
        "formVersion": 1,
        "totalScore": 75 + (index % 25),
        "responses": {
          for (var k = 0; k < 20; k++)
            "field_$k": {
              "value": rng.nextInt(5),
              "comment": k % 3 == 0 ? "Detailed response for field $k" : null,
            },
        },
      },
      // Nested map: context / metadata
      "context": {
        "classificationId": "cls_${index % 6}",
        "variant": index % 2,
        "summary": "Primary context summary for this work item",
        "labelIds": List.generate(3, (j) => "label_${(index + j) % 30}"),
        "stepIds": List.generate(4, (j) => "step_${(index + j) % 20}"),
        "resourceIds": List.generate(2, (j) => "res_${(index + j) % 15}"),
        "measurements": {
          "m1": 60 + rng.nextInt(40),
          "m2": 100 + rng.nextInt(60),
          "m3": 60 + rng.nextInt(30),
          "m4": 12 + rng.nextInt(8),
          "m5": 92 + rng.nextInt(8),
        },
      },
      // Parent tracking (for child documents)
      "parent": {
        "ownerId": "user_${index % 6}",
        "statusIsSame": index % 2 == 0,
      },
      // History array
      "history": List.generate(
        5,
        (j) => {
          "action": j % 3,
          "actorId": "user_${(index + j) % 8}",
          "timestamp": Timestamp.now(),
          "note": "History entry $j for item $index",
        },
      ),
      // Additional fields to reach realistic field count
      "complexity": index % 5,
      "tier": index % 4,
      "reviewStatus": index % 3,
      "blueprintId": "bp_${index % 10}",
      "attachmentCount": index % 3,
      "assigneeNotes": "Notes from the assignee on progress and blockers. " * 2,
      "reviewerFeedback": "Reviewer feedback and recommendations. " * 2,
      "adminNotes": index % 3 == 0 ? "Admin override notes." : null,
      "mutationCounter": 0,
    };
  }

  // -------------------------------------------------------------------------
  // 2. Open concurrent snapshot listeners
  // -------------------------------------------------------------------------

  void _startListeners() {
    if (_listening) {
      return;
    }

    _addLog("Opening $kListenerCount concurrent snapshot listeners...");

    // Listener 1-2: Simple equality queries on a partition field
    for (var t = 0; t < 2; t++) {
      final tenantId = "tenant_$t";
      final sub = _collection
          .where("tenantId", isEqualTo: tenantId)
          .orderBy("dueDate", descending: true)
          .limit(20)
          .snapshots()
          .listen(
            (snap) => _onSnapshot("tenant=$tenantId", snap),
            onError: (Object e) => _addLog("ERROR [tenant=$tenantId]: $e"),
          );
      _listeners.add(sub);
    }

    // Listener 3-4: Filter.or queries (matches direct reviewer OR child docs
    // whose parent has a different status — a common pattern for "items
    // needing my review")
    for (var r = 0; r < 2; r++) {
      final reviewerId = "user_$r";
      final sub = _collection
          .where(
            Filter.or(
              Filter.and(
                Filter("reviewerId", isEqualTo: reviewerId),
                Filter("priority", isEqualTo: 1),
              ),
              Filter("parent.statusIsSame", isEqualTo: false),
            ),
          )
          .orderBy("dueDate", descending: true)
          .limit(20)
          .snapshots()
          .listen(
            (snap) => _onSnapshot("reviewer=$reviewerId", snap),
            onError: (Object e) => _addLog("ERROR [reviewer=$reviewerId]: $e"),
          );
      _listeners.add(sub);
    }

    // Listener 5-6: whereIn queries on status (like "items in these states")
    final statusSets = [
      [0, 1, 2],
      [3, 4, 5],
    ];
    for (var i = 0; i < statusSets.length; i++) {
      final statuses = statusSets[i];
      final sub = _collection
          .where("status", whereIn: statuses)
          .orderBy("dueDate", descending: true)
          .limit(20)
          .snapshots()
          .listen(
            (snap) => _onSnapshot("statuses=$statuses", snap),
            onError: (Object e) => _addLog("ERROR [statuses=$statuses]: $e"),
          );
      _listeners.add(sub);
    }

    // Listener 7: Filter.or with isNull checks (matches top-level items OR
    // child items with independent status — common "org-wide view" pattern)
    {
      final sub = _collection
          .where(
            Filter.or(
              Filter.and(
                Filter("parentId", isNull: true),
                Filter("secondaryParentId", isNull: true),
              ),
              Filter("parent.statusIsSame", isEqualTo: false),
            ),
          )
          .orderBy("dueDate", descending: true)
          .limit(20)
          .snapshots()
          .listen(
            (snap) => _onSnapshot("top-level-or", snap),
            onError: (Object e) => _addLog("ERROR [top-level-or]: $e"),
          );
      _listeners.add(sub);
    }

    // Listener 8: Child document query (items belonging to a specific parent)
    {
      final sub = _collection
          .where("parentId", isEqualTo: "parent_0")
          .where("category", isEqualTo: 2)
          .snapshots()
          .listen(
            (snap) => _onSnapshot("children", snap),
            onError: (Object e) => _addLog("ERROR [children]: $e"),
          );
      _listeners.add(sub);
    }

    _addLog("${_listeners.length} listeners active");
    setState(() => _listening = true);
  }

  void _onSnapshot(String label, QuerySnapshot<Map<String, dynamic>> snap) {
    _snapshotCount++;
    final source = snap.metadata.isFromCache ? "cache" : "server";
    _addLog(
      "SNAPSHOT #$_snapshotCount [$label]: "
      "${snap.docs.length} docs ($source), "
      "${snap.docChanges.length} changes",
    );
  }

  void _stopListeners() {
    for (final sub in _listeners) {
      sub.cancel();
    }
    _listeners.clear();
    _snapshotCount = 0;
    _addLog("All listeners stopped");
    setState(() => _listening = false);
  }

  // -------------------------------------------------------------------------
  // 3. Background CPU load (simulates Sentry session replay video encoding)
  // -------------------------------------------------------------------------

  Future<void> _startCpuLoad() async {
    if (_cpuRunning) {
      return;
    }

    _addLog("Starting background CPU load (simulating video encoding)...");

    final receivePort = ReceivePort();
    _cpuIsolate = await Isolate.spawn(_cpuWorkIsolate, receivePort.sendPort);

    receivePort.listen((message) {
      if (message is String) {
        _addLog("CPU Load Sim: $message");
      }
    });

    setState(() => _cpuRunning = true);
  }

  static void _cpuWorkIsolate(SendPort sendPort) {
    // Simulate continuous CPU-intensive work like AVC video encoding.
    // This runs matrix multiplications in a tight loop to keep a core busy.
    final rng = Random();
    var iteration = 0;

    while (true) {
      final sw = Stopwatch()..start();

      // ~100ms of CPU work per iteration
      var sum = 0.0;
      for (var i = 0; i < 500000; i++) {
        sum += (rng.nextDouble() * rng.nextDouble()).abs();
      }
      sw.stop();

      iteration++;
      if (iteration % 50 == 0) {
        sendPort.send(
          "iteration $iteration, ${sw.elapsedMilliseconds}ms/iter, sum=$sum",
        );
      }
    }
  }

  void _stopCpuLoad() {
    _cpuIsolate?.kill(priority: Isolate.immediate);
    _cpuIsolate = null;
    _addLog("CPU load sim stopped");
    setState(() => _cpuRunning = false);
  }

  // -------------------------------------------------------------------------
  // 4. Canary writer — automated latency measurement
  // -------------------------------------------------------------------------

  /// How often to write a new canary value.
  static const _canaryInterval = Duration(seconds: 3);

  /// A write whose snapshot hasn't arrived within this window is "missed."
  static const _canaryTimeout = Duration(seconds: 10);

  DocumentReference<Map<String, dynamic>> get _canaryDoc =>
      _collection.doc("_canary");

  void _startCanary() {
    if (_canaryRunning) {
      return;
    }

    _canaryWrites = 0;
    _canaryReceived = 0;
    _canaryMissed = 0;
    _canaryMaxLatencyMs = 0;
    _canaryTotalLatencyMs = 0;
    _pendingCanaryWrites.clear();

    // Listen for canary doc changes — match by sequence number
    _canarySub = _canaryDoc.snapshots().listen((snap) {
      if (!snap.exists) {
        return;
      }

      final seq = snap.data()?["seq"] as int?;

      if (seq == null) {
        return;
      }

      final sw = _pendingCanaryWrites.remove(seq);

      if (sw == null) {
        // Already counted (timeout or duplicate snapshot)
        return;
      }

      sw.stop();
      final ms = sw.elapsedMilliseconds;
      _canaryReceived++;
      _canaryTotalLatencyMs += ms;

      if (ms > _canaryMaxLatencyMs) {
        _canaryMaxLatencyMs = ms;
      }

      final avgMs = _canaryTotalLatencyMs ~/ _canaryReceived;
      final label = ms > _canaryTimeout.inMilliseconds
          ? "CANARY SLOW"
          : "CANARY";

      _addLog(
        "$label #$seq: ${ms}ms "
        "(avg: ${avgMs}ms, max: ${_canaryMaxLatencyMs}ms, "
        "missed: $_canaryMissed)",
      );
    }, onError: (Object e) => _addLog("CANARY ERROR: $e"));

    // Periodic writer
    _canaryTimer = Timer.periodic(_canaryInterval, (_) => _writeCanary());

    // Periodic timeout sweep — check for stalled writes every second
    _canaryTimeoutTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _sweepCanaryTimeouts(),
    );

    // First write immediately
    _writeCanary();

    _addLog(
      "Canary started — writing every ${_canaryInterval.inSeconds}s, "
      "timeout ${_canaryTimeout.inSeconds}s",
    );
    setState(() => _canaryRunning = true);
  }

  Future<void> _writeCanary() async {
    _canaryWrites++;
    final seq = _canaryWrites;

    _pendingCanaryWrites[seq] = Stopwatch()..start();
    _addLog("CANARY WRITE #$seq");

    try {
      await _canaryDoc.set({"seq": seq, "writtenAt": Timestamp.now()});
    } catch (e) {
      _pendingCanaryWrites.remove(seq);
      _addLog("CANARY WRITE ERROR #$seq: $e");
    }
  }

  void _sweepCanaryTimeouts() {
    final expired = <int>[];

    for (final entry in _pendingCanaryWrites.entries) {
      if (entry.value.elapsedMilliseconds > _canaryTimeout.inMilliseconds) {
        expired.add(entry.key);
      }
    }

    for (final seq in expired) {
      final sw = _pendingCanaryWrites.remove(seq)!;
      sw.stop();
      _canaryMissed++;
      _addLog(
        "CANARY MISSED #$seq — no snapshot after "
        "${sw.elapsedMilliseconds}ms (total missed: $_canaryMissed)",
      );
    }
  }

  void _stopCanary() {
    _canaryTimer?.cancel();
    _canaryTimer = null;
    _canaryTimeoutTimer?.cancel();
    _canaryTimeoutTimer = null;
    _canarySub?.cancel();
    _canarySub = null;
    _pendingCanaryWrites.clear();

    if (_canaryWrites > 0) {
      final avgMs = _canaryReceived > 0
          ? _canaryTotalLatencyMs ~/ _canaryReceived
          : 0;
      _addLog(
        "CANARY SUMMARY: $_canaryWrites writes, "
        "$_canaryReceived received, $_canaryMissed missed, "
        "avg: ${avgMs}ms, max: ${_canaryMaxLatencyMs}ms",
      );
    }

    _addLog("Canary stopped");
    setState(() => _canaryRunning = false);
  }

  // -------------------------------------------------------------------------
  // 5. Cleanup
  // -------------------------------------------------------------------------

  Future<void> _deleteAll() async {
    _stopCanary();
    _stopListeners();
    _stopCpuLoad();

    _addLog("Deleting all test documents...");
    final snap = await _collection.get();
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in snap.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
    _addLog("Deleted ${snap.docs.length} documents");
    setState(() => _seeded = false);
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  void dispose() {
    _onGlobalLog = null;
    _stopCanary();
    _stopListeners();
    _stopCpuLoad();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Firestore 26.0.2\nPerformance Regression"),
      ),
      body: Column(
        children: [
          // Action steps
          ListTile(
            leading: const _StepNumber(1),
            title: const Text("Seed Data"),
            subtitle: Text("$kDocCount docs with nested maps & blobs"),
            trailing: const Icon(Icons.cloud_upload),
            onTap: _seeded ? null : _seedData,
            dense: true,
          ),
          ListTile(
            leading: const _StepNumber(2),
            title: Text(_listening ? "Stop Listeners" : "Start Listeners"),
            subtitle: Text("$kListenerCount concurrent snapshot listeners"),
            trailing: Icon(_listening ? Icons.stop : Icons.hearing),
            onTap: !_seeded
                ? null
                : _listening
                ? _stopListeners
                : _startListeners,
            dense: true,
          ),
          ListTile(
            title: Text(_cpuRunning ? "Stop CPU Load" : "Start CPU Load"),
            subtitle: const Text("Optional — background isolate work"),
            trailing: Icon(_cpuRunning ? Icons.stop : Icons.memory),
            onTap: _cpuRunning ? _stopCpuLoad : _startCpuLoad,
            dense: true,
          ),
          ListTile(
            leading: const _StepNumber(3),
            title: Text(_canaryRunning ? "Stop Canary" : "Start Canary"),
            subtitle: Text(
              _canaryRunning
                  ? "Writes: $_canaryWrites, received: $_canaryReceived, "
                        "missed: $_canaryMissed"
                  : "Auto-writes every ${_canaryInterval.inSeconds}s, "
                        "measures snapshot latency",
            ),
            trailing: Icon(_canaryRunning ? Icons.stop : Icons.monitor_heart),
            onTap: !_listening
                ? null
                : _canaryRunning
                ? _stopCanary
                : _startCanary,
            dense: true,
          ),
          ListTile(
            title: const Text("Cleanup"),
            subtitle: const Text("Delete all test documents"),
            trailing: const Icon(Icons.delete_forever),
            onTap: _deleteAll,
            dense: true,
          ),
          const Divider(height: 1),
          // Status bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusChip(
                  "Docs",
                  _seeded ? "$kDocCount" : "0",
                  _seeded ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                _StatusChip(
                  "Listeners",
                  "${_listeners.length}",
                  _listening ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                _StatusChip(
                  "CPU",
                  _cpuRunning ? "ON" : "OFF",
                  _cpuRunning ? Colors.orange : Colors.grey,
                ),
                const SizedBox(width: 8),
                _StatusChip("Snapshots", "$_snapshotCount", Colors.blue),
              ],
            ),
          ),
          const Divider(height: 1),
          // Log output
          Expanded(
            child: SafeArea(
              child: SelectionArea(
                child: Container(
                  color: Colors.black87,
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: _globalLog.length,
                    itemBuilder: (context, index) {
                      final line = _globalLog[index];
                      final color = line.contains("CANARY MISSED")
                          ? Colors.red
                          : line.contains("CANARY SLOW")
                          ? Colors.deepOrange
                          : line.contains("CANARY")
                          ? Colors.cyanAccent
                          : line.contains("ERROR")
                          ? Colors.red
                          : line.contains("WARNING")
                          ? Colors.yellow
                          : line.contains("SNAPSHOT")
                          ? Colors.greenAccent
                          : line.contains("CPU")
                          ? Colors.orange
                          : Colors.white70;
                      return Text(
                        line,
                        style: TextStyle(
                          fontFamily: "monospace",
                          fontSize: 11,
                          color: color,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepNumber extends StatelessWidget {
  final int step;

  const _StepNumber(this.step);

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 12,
      child: Text("$step", style: const TextStyle(fontSize: 12)),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatusChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: CircleAvatar(backgroundColor: color, radius: 6),
      label: Text("$label: $value", style: const TextStyle(fontSize: 12)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}
