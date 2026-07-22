import 'package:flutter/material.dart';
import 'package:luna_tv/services/content_filter_service.dart';
import 'package:luna_tv/utils/text_context_menu.dart';

class FilterSettingsScreen extends StatefulWidget {
  const FilterSettingsScreen({super.key});

  @override
  State<FilterSettingsScreen> createState() => _FilterSettingsScreenState();
}

class _FilterSettingsScreenState extends State<FilterSettingsScreen> {
  bool _enabled = false;
  List<String> _rules = [];
  final _controller = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await ContentFilterService.isEnabled();
    final rules = await ContentFilterService.getUserRules();
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _rules = rules;
        _loading = false;
      });
    }
  }

  Future<void> _toggleEnabled(bool v) async {
    await ContentFilterService.setEnabled(v);
    if (mounted) setState(() => _enabled = v);
  }

  Future<void> _addRule(String rule) async {
    if (rule.trim().isEmpty) return;
    final newRules = List<String>.from(_rules)..add(rule.trim());
    await ContentFilterService.setUserRules(newRules);
    if (mounted) setState(() => _rules = newRules);
    _controller.clear();
  }

  Future<void> _removeRule(String rule) async {
    final newRules = List<String>.from(_rules)..remove(rule);
    await ContentFilterService.setUserRules(newRules);
    if (mounted) setState(() => _rules = newRules);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('内容过滤'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  title: const Text('启用关键词过滤'),
                  subtitle: const Text('在搜索结果中屏蔽包含此关键词的条目'),
                  value: _enabled,
                  onChanged: _toggleEnabled,
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          contextMenuBuilder: chineseTextSelectionToolbarBuilder,
                          decoration: const InputDecoration(
                            labelText: '添加关键词',
                            border: OutlineInputBorder(),
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          onSubmitted: _addRule,
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: () => _addRule(_controller.text),
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('当前规则（点击删除）', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (_rules.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('暂无过滤规则', textAlign: TextAlign.center, style: TextStyle(color: Colors.black38)),
                  )
                else
                  ..._rules
                      .map(
                        (r) => ListTile(
                          title: Text(r),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                            onPressed: () => _removeRule(r),
                          ),
                          onTap: () => _removeRule(r),
                        ),
                      )
                      .toList(),
              ],
            ),
    );
  }
}
