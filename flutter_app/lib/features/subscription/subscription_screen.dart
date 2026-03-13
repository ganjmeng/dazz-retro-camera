import 'package:flutter/material.dart';

/// 订阅页（商业化预留占位）
class SubscriptionScreen extends StatelessWidget {
  const SubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
      body: Column(
        children: [
          // 功能展示区（占位）
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.star, color: Colors.amber, size: 64),
                  SizedBox(height: 16),
                  Text(
                    '解锁全部相机与功能',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // 购买按钮区
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                // 年订阅
                _buildPurchaseButton(
                  title: '¥ 68 / 年',
                  subtitle: '支持家庭共享',
                  isHighlighted: true,
                  onTap: () {},
                ),
                const SizedBox(height: 12),
                // 买断
                _buildPurchaseButton(
                  title: '¥ 198 / 永久',
                  subtitle: '一次性购买',
                  isHighlighted: false,
                  onTap: () {},
                ),
              ],
            ),
          ),
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
