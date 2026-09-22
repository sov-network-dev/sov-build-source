import 'package:flutter/material.dart';
import 'enrollment_screen.dart';
import 'permissions_bundle_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  final List<_OnboardingPage> _pages = const [
    _OnboardingPage(
      icon: '🌍',
      title: 'Welcome to SOV',
      body:
      'A sovereign network built for every human on earth. '
          'Your identity, your money, your rules.',
    ),
    _OnboardingPage(
      icon: '🔑',
      title: 'You Are the Bank',
      body:
      'Your SOV wallet lives entirely on your phone. '
          'No company, no government, no bank can touch your funds.',
    ),
    _OnboardingPage(
      icon: '📡',
      title: 'Always Connected',
      body:
      'Eight connectivity modes including mesh, Bluetooth, '
          'and offline DTN ensure you can transact anywhere on earth.',
    ),
    _OnboardingPage(
      icon: '🤝',
      title: 'One Human, One Node',
      body:
      'Your node is tied to your living presence. '
          'No bots, no duplicates. Every citizen is real.',
    ),
    _OnboardingPage(
      icon: '⚡',
      title: 'Tap to Pay',
      body:
      'Pay anyone in 3 seconds by tapping phones together. '
          'No internet required.',
    ),
    _OnboardingPage(
      icon: '🛡️',
      title: 'Funds That Can Never Be Lost',
      body:
      'Lock SOV for your family in a Vault with a claim key and private clues. '
          'While you stay active it is untouchable. If you are ever gone for '
          '20 years, the network helps your family find and claim it. '
          'Return any time — your funds are instantly yours again.',
    ),
  ];

  void _goToPermissionsThenEnrollment() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (ctx) => PermissionsBundleScreen(
          onComplete: () => Navigator.pushReplacement(
            ctx,
            MaterialPageRoute(builder: (_) => const EnrollmentScreen()),
          ),
        ),
      ),
    );
  }

  void _nextPage() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _goToPermissionsThenEnrollment();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A1A),
      body: SafeArea(
        child: Column(
          children: [
            // Skip button
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: _goToPermissionsThenEnrollment,
                child: const Text(
                  'Skip',
                  style: TextStyle(color: Colors.white38),
                ),
              ),
            ),

            // Pages
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (i) =>
                    setState(() => _currentPage = i),
                itemCount: _pages.length,
                itemBuilder: (_, i) => _pages[i],
              ),
            ),

            // Dots indicator
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _pages.length,
                    (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _currentPage == i ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _currentPage == i
                        ? const Color(0xFF00D4AA)
                        : Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 32),

            // Next / Get Started button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _nextPage,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00D4AA),
                    foregroundColor: const Color(0xFF0A0A1A),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    _currentPage == _pages.length - 1
                        ? 'Get Started'
                        : 'Next',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  final String icon;
  final String title;
  final String body;

  const _OnboardingPage({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(icon, style: const TextStyle(fontSize: 80)),
          const SizedBox(height: 32),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 16,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}