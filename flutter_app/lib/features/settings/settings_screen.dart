import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../services/subscription_service.dart';
import '../../router/app_router.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(subscriptionServiceProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: Colors.black,
      ),
      body: ListView(
        children: [
          // 订阅状态横幅
          GestureDetector(
            onTap: isPro ? null : () => context.push(AppRoutes.subscription),
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isPro 
                    ? [Colors.amber.shade700, Colors.amber.shade900]
                    : [Colors.grey.shade800, Colors.grey.shade900],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.star, color: isPro ? Colors.white : Colors.amber, size: 32),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isPro ? 'DAZZ Pro 会员' : '升级 DAZZ Pro',
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isPro ? '已解锁全部相机与高级功能' : '解锁所有复古相机、高画质导出与无水印',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (!isPro)
                    const Icon(Icons.chevron_right, color: Colors.white),
                ],
              ),
            ),
          ),
          
          if (!isPro)
            ListTile(
              leading: const Icon(Icons.restore, color: Colors.white),
              title: const Text('恢复购买', style: TextStyle(color: Colors.white)),
              onTap: () async {
                final success = await ref.read(subscriptionServiceProvider.notifier).restorePurchases();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(success ? '恢复购买成功！' : '未找到可恢复的购买记录。')),
                  );
                }
              },
            ),
            
          const Divider(color: Colors.grey),
          
          const ListTile(
            leading: Icon(Icons.info_outline, color: Colors.white),
            title: Text('关于', style: TextStyle(color: Colors.white)),
            trailing: Icon(Icons.chevron_right, color: Colors.grey),
          ),
          const ListTile(
            leading: Icon(Icons.privacy_tip_outlined, color: Colors.white),
            title: Text('隐私政策', style: TextStyle(color: Colors.white)),
            trailing: Icon(Icons.chevron_right, color: Colors.grey),
          ),
          const ListTile(
            leading: Icon(Icons.description_outlined, color: Colors.white),
            title: Text('用户协议', style: TextStyle(color: Colors.white)),
            trailing: Icon(Icons.chevron_right, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
