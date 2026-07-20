import 'dart:isolate';
import 'dart:ui';

const _portName = 'better_keep.reminder_action_ui';

ReceivePort? _receivePort;

bool attachReminderActionUiChannel(void Function(Object? message) onMessage) {
  detachReminderActionUiChannel();

  final port = ReceivePort();
  if (!IsolateNameServer.registerPortWithName(port.sendPort, _portName)) {
    port.close();
    return false;
  }

  _receivePort = port;
  port.listen(onMessage);
  return true;
}

void detachReminderActionUiChannel() {
  IsolateNameServer.removePortNameMapping(_portName);
  _receivePort?.close();
  _receivePort = null;
}

bool signalReminderActionUi(Object message) {
  final port = IsolateNameServer.lookupPortByName(_portName);
  if (port == null) return false;
  port.send(message);
  return true;
}
