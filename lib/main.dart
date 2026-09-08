import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tagentra/card_library.dart';
import 'package:tagentra_pm3/tagentra_pm3.dart';

void main() => runApp(const TagentraApp());

class TagentraApp extends StatelessWidget {
  const TagentraApp({super.key, this.client});
  final TagentraPm3? client;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tagentra',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff006c67)),
      useMaterial3: true,
      cardTheme: const CardThemeData(elevation: 0),
    ),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff5edbd2),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    home: TagentraHome(client: client ?? TagentraPm3()),
  );
}

class TagentraHome extends StatefulWidget {
  const TagentraHome({super.key, required this.client});
  final TagentraPm3 client;
  @override
  State<TagentraHome> createState() => _TagentraHomeState();
}

class _TagentraHomeState extends State<TagentraHome> {
  int index = 0;
  final devices = <String, Map<String, Object?>>{};
  final logs = <String>[];
  StreamSubscription<TagentraPm3Event>? subscription;
  String connection = '未连接';
  CardLibrary? library;

  @override
  void initState() {
    super.initState();
    subscription = widget.client.events.listen(
      (event) {
        if (!mounted) return;
        setState(() {
          if (event.type == 'device') {
            devices[event.payload['id']! as String] = event.payload;
          }
          if (event.type == 'connection') {
            connection = event.payload['state']?.toString() ?? connection;
          }
          if (event.type == 'log') {
            logs.add(event.payload['message']?.toString() ?? '');
          }
          if (logs.length > 1000) logs.removeRange(0, 200);
        });
      },
      onError: (Object error) {
        if (mounted) setState(() => logs.add('插件事件错误：$error'));
      },
    );
    _openLibrary();
  }

  Future<void> _openLibrary() async {
    try {
      final path = await widget.client.applicationSupportDirectory();
      final opened = CardLibrary(
        Directory('$path${Platform.pathSeparator}cards'),
      );
      await opened.open();
      if (mounted) setState(() => library = opened);
    } on Object catch (error) {
      if (mounted) setState(() => logs.add('卡库初始化失败：$error'));
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      DevicesPage(
        client: widget.client,
        devices: devices.values.toList(),
        connection: connection,
      ),
      WorkbenchPage(client: widget.client, logs: logs),
      CardLibraryPage(cards: library?.cards ?? const []),
      SettingsPage(client: widget.client),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tagentra'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Chip(
                avatar: Icon(
                  connection == 'ready'
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  size: 18,
                ),
                label: Text(connection),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(child: pages[index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bluetooth_searching),
            label: '设备',
          ),
          NavigationDestination(icon: Icon(Icons.terminal), label: '工作台'),
          NavigationDestination(icon: Icon(Icons.style_outlined), label: '卡库'),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

class DevicesPage extends StatelessWidget {
  const DevicesPage({
    super.key,
    required this.client,
    required this.devices,
    required this.connection,
  });
  final TagentraPm3 client;
  final List<Map<String, Object?>> devices;
  final String connection;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('PM3 SE Hub Mini', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 6),
      const Text('通过 Nordic UART 发现设备。App 进入后台后会主动取消命令并断开。'),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => client.startScan(),
        icon: const Icon(Icons.radar),
        label: const Text('扫描设备'),
      ),
      const SizedBox(height: 12),
      if (devices.isEmpty)
        const Card(
          child: ListTile(
            leading: Icon(Icons.bluetooth),
            title: Text('尚未发现设备'),
            subtitle: Text('确认蓝牙已开启并让 Hub Mini 保持可连接状态。'),
          ),
        ),
      for (final device in devices)
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.sensors)),
            title: Text(device['name']?.toString() ?? 'Hub Mini'),
            subtitle: Text('RSSI ${device['rssi'] ?? '—'} · ${device['id']}'),
            trailing: FilledButton.tonal(
              onPressed: () => client.connect(device['id']! as String),
              child: const Text('连接'),
            ),
          ),
        ),
      if (connection == 'ready')
        OutlinedButton.icon(
          onPressed: client.disconnect,
          icon: const Icon(Icons.link_off),
          label: const Text('断开'),
        ),
    ],
  );
}

class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({super.key, required this.client, required this.logs});
  final TagentraPm3 client;
  final List<String> logs;
  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  final controller = TextEditingController();
  final history = <String>[];
  bool running = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> run() async {
    final command = controller.text.trim();
    if (command.isEmpty || running) return;
    setState(() {
      running = true;
      history.add(command);
    });
    try {
      await widget.client.execute(command);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
    if (mounted) setState(() => running = false);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Capability(icon: Icons.credit_card, label: 'MIFARE Classic'),
            _Capability(icon: Icons.nfc, label: 'MFU / NTAG'),
            _Capability(icon: Icons.wifi_tethering, label: 'ISO15693'),
            _Capability(icon: Icons.settings_input_antenna, label: 'LF'),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: widget.logs.length,
              itemBuilder: (_, i) => SelectableText(
                widget.logs[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                onSubmitted: (_) => run(),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'PM3 命令',
                  hintText: '例如：hw version',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: running ? widget.client.cancel : run,
              icon: Icon(running ? Icons.stop : Icons.send),
            ),
          ],
        ),
        if (history.isNotEmpty)
          Text(
            '最近：${history.reversed.take(3).join('  ·  ')}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    ),
  );
}

class _Capability extends StatelessWidget {
  const _Capability({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) =>
      Chip(avatar: Icon(icon, size: 18), label: Text(label));
}

class CardLibraryPage extends StatefulWidget {
  const CardLibraryPage({super.key, required this.cards});
  final List<StoredCard> cards;
  @override
  State<CardLibraryPage> createState() => _CardLibraryPageState();
}

class _CardLibraryPageState extends State<CardLibraryPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final needle = query.trim().toLowerCase();
    final cards = widget.cards.where((card) {
      return needle.isEmpty ||
          card.name.toLowerCase().contains(needle) ||
          card.uid.toLowerCase().contains(needle) ||
          card.tags.any((tag) => tag.toLowerCase().contains(needle));
    }).toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('本地卡库', style: Theme.of(context).textTheme.headlineSmall),
        const Text('Dump 与原始导入文件仅保存在本机。写卡前必须完成容量检查、自动备份与确认。'),
        const SizedBox(height: 16),
        SearchBar(
          leading: const Icon(Icons.search),
          hintText: '名称、UID、标签或备注',
          onChanged: (value) => setState(() => query = value),
        ),
        const SizedBox(height: 12),
        if (cards.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.inventory_2_outlined),
              title: Text('卡库为空'),
              subtitle: Text(
                '从工作台读取卡片，或导入 .bin / .dump / .mfd / .json / .eml。',
              ),
            ),
          ),
        for (final card in cards)
          Card(
            child: ListTile(
              leading: const Icon(Icons.nfc),
              title: Text(card.name),
              subtitle: Text('${card.cardType} · ${card.uid}'),
              trailing: Text(card.dataFormat.toUpperCase()),
            ),
          ),
      ],
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.client});
  final TagentraPm3 client;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const ListTile(
        leading: Icon(Icons.shield_outlined),
        title: Text('离线优先'),
        subtitle: Text('无账号、公告、联网认证或遥测。'),
      ),
      const ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('Tagentra 1.0'),
        subtitle: Text('iOS 15+ · GPL-3.0-or-later'),
      ),
      ListTile(
        leading: const Icon(Icons.description_outlined),
        title: const Text('导出脱敏诊断'),
        subtitle: const Text('包含 BLE、characteristic、TCP、模式与 PM3 日志'),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          try {
            final path = await client.exportDiagnostics();
            messenger.showSnackBar(SnackBar(content: Text('已导出：$path')));
          } catch (error) {
            messenger.showSnackBar(SnackBar(content: Text('$error')));
          }
        },
      ),
    ],
  );
}
