import 'package:flutter/material.dart';

/// 设置页面
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _darkMode = false;
  bool _autoStart = false;
  String _activationCode = '';
  // ignore: unused_field

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text(
            '设置',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          // 激活区
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('授权激活', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextField(
                    onChanged: (v) => _activationCode = v,
                    decoration: const InputDecoration(
                      labelText: '激活码',
                      hintText: 'TERM-XXXX-XXXX-XXXX-XXXX',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton(
                      onPressed: () {
                        // LicenseManager.activate(_activationCode)
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('激活码: $_activationCode')),
                        );
                      },
                      child: const Text('激活'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 开关设置
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('深色模式'),
                  subtitle: const Text('使用深色主题'),
                  value: _darkMode,
                  onChanged: (v) => setState(() => _darkMode = v),
                ),
                SwitchListTile(
                  title: const Text('开机自启'),
                  subtitle: const Text('系统启动时自动运行'),
                  value: _autoStart,
                  onChanged: (v) => setState(() => _autoStart = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 关于
          Card(
            child: ListTile(
              leading: const Icon(Icons.info),
              title: const Text('关于 Remote PC Control'),
              subtitle: const Text('版本 1.0.0 · Flutter 跨平台版'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            ),
          ),
        ],
      ),
    );
  }
}
