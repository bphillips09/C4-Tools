import 'package:flutter/material.dart';
import 'package:c4_tools/tools/http_client.dart';
import 'dart:convert';

class SystemStatusScreen extends StatefulWidget {
  final String directorIP;
  final String jwtToken;

  const SystemStatusScreen({
    Key? key,
    required this.directorIP,
    required this.jwtToken,
  }) : super(key: key);

  @override
  State<SystemStatusScreen> createState() => _SystemStatusScreenState();
}

class _SystemStatusScreenState extends State<SystemStatusScreen> {
  Map<String, String>? _statusMap;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchSystemStatus();
  }

  Future<void> _fetchSystemStatus() async {
    try {
      final url = 'https://${widget.directorIP}:443/api/v1/sysman/status';
      final client = httpIOClient();
      final response = await client.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer ${widget.jwtToken}',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _statusMap = Map<String, String>.from(data);
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage =
              'Failed to fetch system status (Status: ${response.statusCode})';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  Future<void> _updateServiceStatus(String service, String newStatus) async {
    try {
      final url = 'https://${widget.directorIP}:443/api/v1/sysman/status';
      final client = httpIOClient();

      // Create a copy of the current status map and update the service
      final updatedStatus = Map<String, String>.from(_statusMap!);
      updatedStatus[service] = newStatus;

      final response = await client.post(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.jwtToken}',
        },
        body: jsonEncode(updatedStatus),
      );

      if (response.statusCode == 200) {
        setState(() {
          _statusMap = updatedStatus;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$service status updated successfully')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Failed to update $service status (Status: ${response.statusCode})'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('System Status'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(child: Text(_errorMessage!))
              : _statusMap == null
                  ? const Center(child: Text('No status data available'))
                  : ListView.builder(
                      itemCount: _statusMap!.length,
                      itemBuilder: (context, index) {
                        final service = _statusMap!.keys.elementAt(index);
                        final status = _statusMap![service]!;
                        return Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: ListTile(
                            title: Text(
                              service,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: status == 'enabled'
                                        ? Colors.green
                                        : Colors.red,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                PopupMenuButton<String>(
                                  onSelected: (newStatus) {
                                    _updateServiceStatus(service, newStatus);
                                  },
                                  itemBuilder: (context) => [
                                    const PopupMenuItem(
                                      value: 'enabled',
                                      child: Text('Enable'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'disabled',
                                      child: Text('Disable'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
