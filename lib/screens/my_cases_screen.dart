import 'package:flutter/material.dart';

class MyCasesScreen extends StatefulWidget {
  const MyCasesScreen({Key? key}) : super(key: key);

  @override
  _MyCasesScreenState createState() => _MyCasesScreenState();
}

class _MyCasesScreenState extends State<MyCasesScreen> {
  bool _isLoading = true;
  List<dynamic> _cases = [];

  @override
  void initState() {
    super.initState();
    _fetchCases();
  }

  Future<void> _fetchCases() async {
    // TODO: Dispatch message to relay to fetch disputes where user is plaintiff or defendant
    // For now, simulate network fetch
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) {
      setState(() {
        _cases = []; // Will be populated with real case data
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Justice Cases'),
        backgroundColor: Colors.black,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.teal))
          : _cases.isEmpty
              ? _buildEmptyState()
              : _buildCasesList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.gavel, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No Active Cases',
            style: TextStyle(fontSize: 18, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          const Text(
            'You have not filed any disputes,\nand no disputes have been filed against you.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _buildCasesList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _cases.length,
      itemBuilder: (context, index) {
        final c = _cases[index];
        final bool isClosed = c['status'] == 'closed';
        // Check if within 48h appeal window (placeholder logic)
        final bool isWithinAppeal = isClosed; 

        return Card(
          color: Colors.grey[900],
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Case ${c['case_id']?.toString().substring(0, 8) ?? 'Unknown'}', 
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.tealAccent)),
                    Chip(
                      label: Text(c['status']?.toString().toUpperCase() ?? 'OPEN', 
                          style: const TextStyle(fontSize: 10, color: Colors.white)),
                      backgroundColor: isClosed ? Colors.red[900] : Colors.teal[900],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Plaintiff: ${c['plaintiff_id']}', style: const TextStyle(color: Colors.white70)),
                Text('Defendant: ${c['defendant_id']}', style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Text('Claim: ${c['claim_amount']} SOV', style: const TextStyle(color: Colors.orangeAccent)),
                
                if (isClosed && c['verdict'] != null) ...[
                  const Divider(color: Colors.grey),
                  Text('Verdict: ${c['verdict']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  if (isWithinAppeal)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.assignment_return, color: Colors.tealAccent),
                        label: const Text('APPEAL', style: TextStyle(color: Colors.tealAccent)),
                        onPressed: () {
                          // Route to DisputeFilingScreen with appeal_of prepopulated
                        },
                      ),
                    )
                ]
              ],
            ),
          ),
        );
      },
    );
  }
}