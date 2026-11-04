import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/phone_link_state.dart';
import '../../state/remote_agents_state.dart';
import 'phone_pairing.dart';
import '../../state/phone_state.dart';
import '../../state/phone_turn_end.dart';

/// Keeps [phoneStopWatcherProvider] alive under the home shell, so 停止 on
/// the phone-control overlay also ends the running turn while the app is in
/// the background; and [phoneTurnEndProvider], so the overlay closes (and the
/// app comes back) when that turn ends; and [phoneConfirmPendingProvider], so
/// a first-run 确认方式 the phone didn't take yet goes in on the next start; and
/// [phoneLinksProvider], so agents on computers reach the phone in the background.
class PhoneStopWatcher extends ConsumerWidget {
  const PhoneStopWatcher({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(phoneStopWatcherProvider);
    ref.watch(phoneTurnEndProvider);
    ref.watch(phoneConfirmPendingProvider);
    // Computers whose agents may use the phone stay attached with the app in the background.
    ref.watch(phoneLinksProvider);
    // `dshgo://link?…`: a computer's pairing link (its QR code, opened by the camera).
    ref.watch(phonePairingRouteProvider);
    // Agent sessions on computers stay listed (and their turn ends reach phone tasks).
    ref.watch(remoteAgentsProvider);
    return child;
  }
}
