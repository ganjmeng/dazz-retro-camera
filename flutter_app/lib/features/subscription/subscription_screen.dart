import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../../services/subscription_service.dart';

/// 订阅页（商业化）
class SubscriptionScreen extends ConsumerStatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  ConsumerState<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends ConsumerState<SubscriptionScreen> {
  List<Package> _packages = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadOfferings();
  }

  Future<void> _loadOfferings() async {
    final packages = await ref.read(subscriptionServiceProvider.notifier).getOfferings();
    if (mounted) {
      setState(() {
        _packages = packages;
        _isLoading = false;
      });
    }
  }

  Future<void> _purchase(Package package) async {
    setState(() => _isLoading = true);
    final success = await ref.read(subscriptionServiceProvider.notifier).purchasePackage(package);
    if (mounted) {
      setState(() => _isLoading = false);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('购买成功！已解锁全部功能。')),
        );
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _restorePurchases() async {
    setState(() => _isLoading = true);
    final success = await ref.read(subscriptionServiceProvider.notifier).restorePurchases();
    if (mounted) {
      setState(() => _isLoading = false);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('恢复购买成功！')),
        );
        Navigator.of(context).pop();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到可恢复的购买记录。')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPro = ref.watch(subscriptionServiceProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Pro 会员'),
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // 功能展示区
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.star, color: Colors.amber, size: 64),
                      const SizedBox(height: 16),
                      Text(
                        isPro ? '您已是 Pro 会员' : '解锁全部相机与功能',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 32),
                      if (!isPro) ...[
                        _buildFeatureRow(Icons.camera_alt, '解锁 10+ 款复古相机'),
                        _buildFeatureRow(Icons.hd, '支持高分辨率导出'),
                        _buildFeatureRow(Icons.branding_watermark, '移除照片水印'),
                        _buildFeatureRow(Icons.block, '无广告纯净体验'),
                      ]
                    ],
                  ),
                ),
              ),
              
              // 购买按钮区
              if (!isPro)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      if (_packages.isEmpty && !_isLoading)
                        const Text('暂无可用订阅项', style: TextStyle(color: Colors.grey)),
                      ..._packages.map((package) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildPurchaseButton(
                            title: package.storeProduct.title,
                            subtitle: package.storeProduct.priceString,
                            isHighlighted: package.packageType == PackageType.annual,
                            onTap: () => _purchase(package),
                          ),
                        );
                      }).toList(),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: _restorePurchases,
                        child: const Text('恢复购买', style: TextStyle(color: Colors.grey)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (_isLoading)
            Container(color: Colors.black54),
          if (_isLoading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }

  Widget _buildFeatureRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 48),
      child: Row(
        children: [
          Icon(icon, color: Colors.amber, size: 24),
          const SizedBox(width: 16),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildPurchaseButton({
    required String title,
    required String subtitle,
    required bool isHighlighted,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: isHighlighted ? Colors.white : Colors.grey[850],
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Text(
              title,
              style: TextStyle(
                color: isHighlighted ? Colors.black : Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              subtitle,
              style: TextStyle(
                color: isHighlighted ? Colors.grey[600] : Colors.grey,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
