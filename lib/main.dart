import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tagentra/card_library.dart';
import 'package:tagentra_pm3/tagentra_pm3.dart';

void main() => runApp(const TagentraApp());

TagentraDeviceMode? _deviceModeFrom(Object? value) {
  final name = value?.toString();
  if (name == null) return null;
  for (final mode in TagentraDeviceMode.values) {
    if (mode.name == name) return mode;
  }
  return TagentraDeviceMode.unknown;
}

String _modeLabel(TagentraDeviceMode mode) => switch (mode) {
  TagentraDeviceMode.pm3 => 'PM3',
  TagentraDeviceMode.chameleon => '变色龙',
  TagentraDeviceMode.unknown => '模式未知',
};

String _connectionLabel(String state) => switch (state) {
  'ready' => '已连接',
  'detecting' => '正在检测',
  'initializing' => '正在初始化',
  'switching' => '正在切换',
  'error' => '连接异常',
  'disconnected' => '未连接',
  _ => state,
};

bool _isConnected(String state) => const {
  'ready',
  'detecting',
  'initializing',
  'switching',
  'error',
}.contains(state);

Future<void> _showCopyableError(
  BuildContext context, {
  required String title,
  required Object error,
}) {
  final message = error.toString();
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.error_outline),
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: SelectableText(message, key: const Key('error-message')),
        ),
      ),
      actions: [
        TextButton.icon(
          key: const Key('copy-error'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: message));
            if (!dialogContext.mounted) return;
            ScaffoldMessenger.of(dialogContext)
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(content: Text('错误信息已复制')));
          },
          icon: const Icon(Icons.copy_outlined),
          label: const Text('复制'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class TagentraApp extends StatelessWidget {
  const TagentraApp({super.key, this.client, this.cardLibrary});
  final TagentraPm3? client;
  final CardLibrary? cardLibrary;

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
    home: TagentraHome(
      client: client ?? TagentraPm3(),
      initialLibrary: cardLibrary,
    ),
  );
}

class TagentraHome extends StatefulWidget {
  const TagentraHome({super.key, required this.client, this.initialLibrary});
  final TagentraPm3 client;
  final CardLibrary? initialLibrary;
  @override
  State<TagentraHome> createState() => _TagentraHomeState();
}

class _TagentraHomeState extends State<TagentraHome> {
  int index = 0;
  final devices = <String, Map<String, Object?>>{};
  final logs = <String>[];
  StreamSubscription<TagentraPm3Event>? subscription;
  String connection = '未连接';
  TagentraDeviceMode deviceMode = TagentraDeviceMode.unknown;
  TagentraDeviceMode? targetMode;
  CardLibrary? library;
  Future<void>? libraryOpen;

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
            deviceMode = _deviceModeFrom(event.payload['mode']) ?? deviceMode;
            targetMode = _deviceModeFrom(event.payload['targetMode']);
            if (connection == 'disconnected') {
              deviceMode = TagentraDeviceMode.unknown;
              targetMode = null;
            } else if (connection != 'switching') {
              targetMode = null;
            }
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
    if (widget.initialLibrary case final initial?) {
      library = initial;
      libraryOpen = Future.value();
    } else {
      libraryOpen = _openLibrary();
    }
  }

  Future<void> _openLibrary() async {
    try {
      final path = await widget.client.applicationSupportDirectory();
      final opened = CardLibrary(
        Directory('$path${Platform.pathSeparator}cards'),
        artifactSourceRoot: Directory('$path${Platform.pathSeparator}PM3'),
      );
      await opened.open();
      final artifacts = await widget.client.listArtifacts();
      final recovered = await opened.importPm3Artifacts(
        artifacts,
        rrgRevision: 'unknown',
      );
      if (mounted) {
        setState(() => library = opened);
        if (recovered.keysWithoutDump.isNotEmpty) {
          _showKeysWithoutDump(recovered.keysWithoutDump);
        }
      }
    } on Object catch (error) {
      if (mounted) setState(() => logs.add('卡库初始化失败：$error'));
    }
  }

  Future<void> _handleCommandResult(TagentraPm3CommandResult result) async {
    await libraryOpen;
    final opened = library;
    if (opened == null) return;
    try {
      List<TagentraPm3Artifact> artifacts;
      try {
        artifacts = await widget.client.listArtifacts();
      } on Object {
        artifacts = result.artifacts;
      }
      final imported = await opened.importPm3Artifacts(
        artifacts,
        rrgRevision: result.rrgRevision,
      );
      if (!mounted) return;
      if (imported.changed) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已将 ${imported.imported.length} 张卡保存到卡库')),
        );
      }
      if (imported.keysWithoutDump.isNotEmpty) {
        _showKeysWithoutDump(imported.keysWithoutDump);
      }
    } on Object catch (error) {
      if (mounted) setState(() => logs.add('产物入库失败：$error'));
    }
  }

  void _showKeysWithoutDump(List<String> uids) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保留 ${uids.join('、')} 的密钥文件；dump 尚未完成')),
    );
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
        mode: deviceMode,
        targetMode: targetMode,
      ),
      WorkbenchPage(
        client: widget.client,
        logs: logs,
        connection: connection,
        mode: deviceMode,
        onResult: _handleCommandResult,
      ),
      CardLibraryPage(
        library: library,
        client: widget.client,
        onChanged: () => setState(() {}),
      ),
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
                  _isConnected(connection)
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  size: 18,
                ),
                label: Text(
                  '${_connectionLabel(connection)} · ${_modeLabel(deviceMode)}',
                ),
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
    required this.mode,
    required this.targetMode,
  });
  final TagentraPm3 client;
  final List<Map<String, Object?>> devices;
  final String connection;
  final TagentraDeviceMode mode;
  final TagentraDeviceMode? targetMode;

  Future<void> _runDeviceAction(
    BuildContext context, {
    required String errorTitle,
    required Future<void> Function() action,
  }) async {
    try {
      await action();
    } on Object catch (error) {
      if (!context.mounted) return;
      await _showCopyableError(context, title: errorTitle, error: error);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('PM3 SE Hub Mini', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 6),
      const Text('通过 Nordic UART 发现设备。App 进入后台后会主动取消命令并断开。'),
      const SizedBox(height: 16),
      _ModeSelector(
        client: client,
        connection: connection,
        mode: mode,
        targetMode: targetMode,
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => _runDeviceAction(
          context,
          errorTitle: '扫描失败',
          action: client.startScan,
        ),
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
              onPressed: () => _runDeviceAction(
                context,
                errorTitle: '连接失败',
                action: () => client.connect(device['id']! as String),
              ),
              child: const Text('连接'),
            ),
          ),
        ),
      if (_isConnected(connection))
        OutlinedButton.icon(
          onPressed: () => _runDeviceAction(
            context,
            errorTitle: '断开连接失败',
            action: client.disconnect,
          ),
          icon: const Icon(Icons.link_off),
          label: const Text('断开'),
        ),
    ],
  );
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({
    required this.client,
    required this.connection,
    required this.mode,
    required this.targetMode,
  });

  final TagentraPm3 client;
  final String connection;
  final TagentraDeviceMode mode;
  final TagentraDeviceMode? targetMode;

  Future<void> _switchMode(
    BuildContext context,
    TagentraDeviceMode selected,
  ) async {
    if (selected == mode) return;
    try {
      if (selected == TagentraDeviceMode.pm3) {
        await client.switchToPm3();
      } else if (selected == TagentraDeviceMode.chameleon) {
        await client.switchToChameleon();
      }
    } on Object catch (error) {
      if (!context.mounted) return;
      await _showCopyableError(context, title: '模式切换失败', error: error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final switching = connection == 'switching';
    final canSwitch = connection == 'ready' && !switching;
    final selectedMode = targetMode ?? mode;
    final selected = selectedMode == TagentraDeviceMode.unknown
        ? <TagentraDeviceMode>{}
        : {selectedMode};

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.device_hub_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '设备模式：${_modeLabel(mode)}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (switching)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            SegmentedButton<TagentraDeviceMode>(
              emptySelectionAllowed: true,
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: TagentraDeviceMode.chameleon,
                  enabled: mode != TagentraDeviceMode.unknown,
                  icon: const Icon(Icons.change_circle_outlined),
                  label: const Text('变色龙'),
                ),
                const ButtonSegment(
                  value: TagentraDeviceMode.pm3,
                  icon: Icon(Icons.memory),
                  label: Text('PM3'),
                ),
              ],
              selected: selected,
              onSelectionChanged: canSwitch
                  ? (values) {
                      if (values.isNotEmpty) {
                        _switchMode(context, values.first);
                      }
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({
    super.key,
    required this.client,
    required this.logs,
    required this.connection,
    required this.mode,
    required this.onResult,
  });
  final TagentraPm3 client;
  final List<String> logs;
  final String connection;
  final TagentraDeviceMode mode;
  final Future<void> Function(TagentraPm3CommandResult result) onResult;
  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  final controller = TextEditingController();
  final commandFocus = FocusNode();
  final history = <String>[];
  bool running = false;

  bool get pm3Ready =>
      widget.connection == 'ready' && widget.mode == TagentraDeviceMode.pm3;

  @override
  void dispose() {
    controller.dispose();
    commandFocus.dispose();
    super.dispose();
  }

  void fillCommand(String command) {
    if (!pm3Ready || running) return;
    controller.value = TextEditingValue(
      text: command,
      selection: TextSelection.collapsed(offset: command.length),
    );
    commandFocus.requestFocus();
    setState(() {});
  }

  Future<void> switchToPm3() async {
    try {
      await widget.client.switchToPm3();
    } on Object catch (error) {
      if (!mounted) return;
      await _showCopyableError(context, title: '模式切换失败', error: error);
    }
  }

  Future<void> run() async {
    final command = controller.text.trim();
    if (command.isEmpty || running || !pm3Ready) return;
    setState(() {
      running = true;
      history.add(command);
    });
    try {
      final result = await widget.client.execute(command);
      await widget.onResult(result);
    } on Object catch (error) {
      if (mounted) {
        await _showCopyableError(context, title: '指令执行失败', error: error);
      }
    }
    if (mounted) setState(() => running = false);
  }

  Future<void> cancel() async {
    try {
      await widget.client.cancel();
    } on Object catch (error) {
      if (!mounted) return;
      await _showCopyableError(context, title: '停止指令失败', error: error);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!pm3Ready) ...[
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.info_outline),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.mode == TagentraDeviceMode.chameleon
                              ? '变色龙模式'
                              : _connectionLabel(widget.connection),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          widget.connection == 'switching'
                              ? '模式切换完成后即可发送 PM3 指令。'
                              : '切换到 PM3 后才能使用指令工作台。',
                        ),
                      ],
                    ),
                  ),
                  if (widget.connection == 'ready' &&
                      widget.mode != TagentraDeviceMode.pm3)
                    FilledButton.tonalIcon(
                      onPressed: switchToPm3,
                      icon: const Icon(Icons.swap_horiz),
                      label: const Text('切换到 PM3'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
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
        Text('快捷指令', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Tooltip(
              message: 'hf 14a info',
              child: ActionChip(
                avatar: const Icon(Icons.nfc, size: 18),
                label: const Text('读取卡片属性'),
                onPressed: pm3Ready && !running
                    ? () => fillCommand('hf 14a info')
                    : null,
              ),
            ),
            Tooltip(
              message: 'hf mf autopwn',
              child: ActionChip(
                key: const Key('autopwn-command'),
                avatar: const Icon(Icons.lock_open_outlined, size: 18),
                label: const Text('一键解卡'),
                onPressed: pm3Ready && !running
                    ? () => fillCommand('hf mf autopwn')
                    : null,
              ),
            ),
            for (final command in const [
              'hw version',
              'hw status',
              'hw tune',
              'hf 15 reader',
              'lf read',
            ])
              ActionChip(
                label: Text(
                  command,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                onPressed: pm3Ready && !running
                    ? () => fillCommand(command)
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                widget.logs.join('\n'),
                key: const Key('console-output'),
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
                focusNode: commandFocus,
                enabled: pm3Ready && !running,
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
              onPressed: running
                  ? cancel
                  : pm3Ready
                  ? run
                  : null,
              icon: Icon(running ? Icons.stop : Icons.send),
              tooltip: running ? '停止指令' : '发送指令',
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
  const CardLibraryPage({
    super.key,
    required this.library,
    required this.client,
    required this.onChanged,
  });
  final CardLibrary? library;
  final TagentraPm3 client;
  final VoidCallback onChanged;
  @override
  State<CardLibraryPage> createState() => _CardLibraryPageState();
}

class _CardLibraryPageState extends State<CardLibraryPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final needle = query.trim().toLowerCase();
    final cards = (widget.library?.cards ?? const <StoredCard>[]).where((card) {
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
              key: Key('card-${card.id}'),
              leading: const Icon(Icons.nfc),
              title: Text(card.name),
              subtitle: Text(
                '${card.cardType} · ${card.uid} · '
                '${card.unlockStatus == CardUnlockStatus.complete ? '密钥完整' : '仅 Dump'}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.library == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => CardDetailsPage(
                          card: card,
                          library: widget.library!,
                          client: widget.client,
                          onChanged: widget.onChanged,
                        ),
                      ),
                    ),
            ),
          ),
      ],
    );
  }
}

class CardDetailsPage extends StatefulWidget {
  const CardDetailsPage({
    super.key,
    required this.card,
    required this.library,
    required this.client,
    required this.onChanged,
  });
  final StoredCard card;
  final CardLibrary library;
  final TagentraPm3 client;
  final VoidCallback onChanged;

  @override
  State<CardDetailsPage> createState() => _CardDetailsPageState();
}

class _CardDetailsPageState extends State<CardDetailsPage> {
  late StoredCard card = widget.card;
  bool showKeys = false;
  final expandedSectors = <int>{};
  Future<List<MifareSectorData>>? sectorData;

  @override
  void initState() {
    super.initState();
    if (card.protocol == CardProtocol.mifareClassic) {
      sectorData = widget.library.readMifareSectors(card);
    }
  }

  Future<void> copyText(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> edit() async {
    final name = TextEditingController(text: card.name);
    final tags = TextEditingController(text: card.tags.join(', '));
    final notes = TextEditingController(text: card.notes);
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑卡片'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('edit-card-name'),
                controller: name,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                key: const Key('edit-card-tags'),
                controller: tags,
                decoration: const InputDecoration(labelText: '标签（逗号分隔）'),
              ),
              TextField(
                key: const Key('edit-card-notes'),
                controller: notes,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '备注'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('save-card-edit'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (save != true || name.text.trim().isEmpty) return;
    final previous = card;
    final nextName = name.text.trim();
    final nextTags = tags.text
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    final nextNotes = notes.text.trim();
    setState(
      () => card = card.copyWith(
        name: nextName,
        tags: nextTags,
        notes: nextNotes,
      ),
    );
    widget.onChanged();
    try {
      final updated = await widget.library.updateMetadata(
        card.id,
        name: nextName,
        tags: nextTags,
        notes: nextNotes,
      );
      if (mounted) setState(() => card = updated);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => card = previous);
      await _showCopyableError(context, title: '保存失败', error: error);
    }
  }

  Future<void> exportArtifacts() async {
    final available = card.artifacts.map((value) => value.kind).toSet();
    final selected = <CardArtifactKind>{...available};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('导出产物'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final kind in CardArtifactKind.values)
                CheckboxListTile(
                  key: Key('export-${kind.name}'),
                  value: selected.contains(kind),
                  enabled: available.contains(kind),
                  title: Text(_artifactLabel(kind)),
                  onChanged: available.contains(kind)
                      ? (value) => update(() {
                          if (value ?? false) {
                            selected.add(kind);
                          } else {
                            selected.remove(kind);
                          }
                        })
                      : null,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              key: const Key('share-selected-artifacts'),
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.ios_share),
              label: const Text('分享'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final files = widget.library.filesForArtifacts(card, selected);
    await widget.client.shareArtifacts(files.map((file) => file.path));
  }

  Future<void> deleteCard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除卡片？'),
        content: Text('将删除“${card.name}”及卡库中的关联产物。此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-delete-card'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.library.delete(card.id);
    widget.onChanged();
    if (mounted) Navigator.pop(context);
  }

  void retrySectorData() {
    setState(() {
      expandedSectors.clear();
      sectorData = widget.library.readMifareSectors(card);
    });
  }

  String blockRole(MifareBlockData block) {
    if (block.block == 0) return '制造商块';
    if (block.isSectorTrailer) return '扇区尾块';
    return '数据块';
  }

  String formatBlockData(MifareBlockData block) {
    final revealTrailerKeys = showKeys && card.sectorKeys.isNotEmpty;
    final values = <String>[];
    for (var index = 0; index < block.bytes.length; index++) {
      final hidesKey =
          block.isSectorTrailer &&
          !revealTrailerKeys &&
          (index < 6 || index >= 10);
      values.add(
        hidesKey
            ? '--'
            : block.bytes[index]
                  .toRadixString(16)
                  .padLeft(2, '0')
                  .toUpperCase(),
      );
    }
    return '${values.take(8).join(' ')}\n${values.skip(8).join(' ')}';
  }

  Widget buildBlockRow(BuildContext context, MifareBlockData block) {
    final offset = block.offset.toRadixString(16).padLeft(4, '0').toUpperCase();
    return DecoratedBox(
      key: Key('block-data-${block.block}'),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 78,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '块 ${block.block}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Text(
                    '0x$offset',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                  Text(
                    blockRole(block),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                formatBlockData(block),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildSectorData(BuildContext context) {
    final future = sectorData;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<List<MifareSectorData>>(
      future: future,
      builder: (context, snapshot) {
        final sectors = snapshot.data;
        final allExpanded =
            sectors != null &&
            sectors.isNotEmpty &&
            sectors.every((sector) => expandedSectors.contains(sector.sector));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '扇区数据',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (sectors != null)
                  TextButton.icon(
                    key: const Key('toggle-all-sectors'),
                    onPressed: () => setState(() {
                      if (allExpanded) {
                        expandedSectors.clear();
                      } else {
                        expandedSectors.addAll(
                          sectors.map((sector) => sector.sector),
                        );
                      }
                    }),
                    icon: Icon(
                      allExpanded ? Icons.unfold_less : Icons.unfold_more,
                    ),
                    label: Text(allExpanded ? '全部折叠' : '全部展开'),
                  ),
              ],
            ),
            if (snapshot.connectionState == ConnectionState.waiting)
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.hourglass_top),
                title: Text('正在读取扇区数据'),
              )
            else if (snapshot.hasError)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.error_outline),
                title: const Text('无法读取扇区数据'),
                subtitle: Text('${snapshot.error}'),
                trailing: IconButton(
                  key: const Key('retry-sector-data'),
                  onPressed: retrySectorData,
                  tooltip: '重试',
                  icon: const Icon(Icons.refresh),
                ),
              )
            else if (sectors != null) ...[
              Text(
                '${sectors.length} 个扇区 · '
                '${sectors.expand((sector) => sector.blocks).length} 个块 · '
                '${sectors.fold(0, (total, sector) => total + sector.byteLength)} 字节',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              ExpansionPanelList(
                elevation: 0,
                materialGapSize: 0,
                expandedHeaderPadding: EdgeInsets.zero,
                dividerColor: Theme.of(context).colorScheme.outlineVariant,
                expansionCallback: (index, isExpanded) {
                  final sector = sectors[index].sector;
                  setState(() {
                    if (isExpanded) {
                      expandedSectors.add(sector);
                    } else {
                      expandedSectors.remove(sector);
                    }
                  });
                },
                children: [
                  for (final sector in sectors)
                    ExpansionPanel(
                      canTapOnHeader: true,
                      isExpanded: expandedSectors.contains(sector.sector),
                      headerBuilder: (context, isExpanded) => ListTile(
                        key: Key('sector-header-${sector.sector}'),
                        title: Text('扇区 ${sector.sector}'),
                        subtitle: Text(
                          '块 ${sector.firstBlock}–${sector.lastBlock} · '
                          '${sector.byteLength} 字节',
                        ),
                      ),
                      body: expandedSectors.contains(sector.sector)
                          ? Column(
                              children: [
                                for (final block in sector.blocks)
                                  buildBlockRow(context, block),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final allKeys = card.sectorKeys
        .map((keys) => '${keys.sector}: A ${keys.keyA}  B ${keys.keyB}')
        .join('\n');
    return Scaffold(
      appBar: AppBar(
        title: Text(card.name),
        actions: [
          IconButton(
            key: const Key('edit-card'),
            onPressed: edit,
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            key: const Key('export-card'),
            onPressed: card.artifacts.isEmpty ? null : exportArtifacts,
            tooltip: '导出',
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            key: const Key('delete-card'),
            onPressed: deleteCard,
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        key: const Key('card-details-scroll'),
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.nfc),
            title: Text(card.cardType),
            subtitle: Text('UID ${card.uid}'),
            trailing: Chip(
              label: Text(
                card.unlockStatus == CardUnlockStatus.complete
                    ? '密钥完整'
                    : '仅 Dump',
              ),
            ),
          ),
          if (card.tags.isNotEmpty)
            Wrap(
              spacing: 6,
              children: card.tags.map((tag) => Chip(label: Text(tag))).toList(),
            ),
          if (card.notes.isNotEmpty) ...[const Divider(), Text(card.notes)],
          const Divider(height: 32),
          Row(
            children: [
              Expanded(
                child: Text(
                  '扇区密钥',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (card.sectorKeys.isNotEmpty)
                TextButton.icon(
                  key: const Key('toggle-keys'),
                  onPressed: () => setState(() => showKeys = !showKeys),
                  icon: Icon(
                    showKeys ? Icons.visibility_off : Icons.visibility,
                  ),
                  label: Text(showKeys ? '隐藏' : '显示'),
                ),
            ],
          ),
          if (card.sectorKeys.isEmpty)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.key_off_outlined),
              title: Text('没有有效密钥文件'),
            )
          else if (!showKeys)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.lock_outline),
              title: Text('密钥已隐藏'),
            )
          else ...[
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('copy-all-keys'),
                onPressed: () => copyText(allKeys, '已复制全部密钥'),
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('复制全部'),
              ),
            ),
            for (final keys in card.sectorKeys)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      SizedBox(width: 48, child: Text('${keys.sector}')),
                      Expanded(
                        child: Text(
                          'A  ${keys.keyA}\nB  ${keys.keyB}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                      IconButton(
                        key: Key('copy-key-a-${keys.sector}'),
                        onPressed: () => copyText(keys.keyA, '已复制 Key A'),
                        tooltip: '复制 Key A',
                        icon: const Icon(Icons.content_copy, size: 19),
                      ),
                      IconButton(
                        key: Key('copy-key-b-${keys.sector}'),
                        onPressed: () => copyText(keys.keyB, '已复制 Key B'),
                        tooltip: '复制 Key B',
                        icon: const Icon(Icons.content_copy, size: 19),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          if (card.protocol == CardProtocol.mifareClassic) ...[
            const Divider(height: 32),
            buildSectorData(context),
          ],
        ],
      ),
    );
  }
}

String _artifactLabel(CardArtifactKind kind) => switch (kind) {
  CardArtifactKind.dumpBin => 'dump.bin',
  CardArtifactKind.dumpJson => 'dump.json',
  CardArtifactKind.keyBin => 'key.bin',
};

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
            if (!context.mounted) return;
            await _showCopyableError(context, title: '导出失败', error: error);
          }
        },
      ),
    ],
  );
}
