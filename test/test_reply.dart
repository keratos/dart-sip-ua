import 'package:sip_ua/src/parser.dart';
import 'package:sip_ua/src/sip_message.dart';
import 'package:sip_ua/src/transactions/transaction_base.dart';
import 'package:test/test.dart';

/// Transaction serveur témoin : garde la réponse que `reply()` lui confie au
/// lieu de l'envoyer sur le réseau.
class _TransactionTemoin extends TransactionBase {
  int? code;
  String? reponse;

  @override
  void onTransportError() {}

  @override
  void send() {}

  @override
  void receiveResponse(int status_code, IncomingMessage response,
      [void Function()? onSuccess, void Function()? onFailure]) {
    code = status_code;
    reponse = response.data;
  }
}

/// BYE reçu dans un dialogue : c'est sur un BYE en mauvais état que
/// `RTCSession` répond `403 Wrong Status`.
const String bye = 'BYE sip:100@192.0.2.1;transport=ws SIP/2.0\r\n'
    'Via: SIP/2.0/WSS 192.0.2.2:8089;rport;branch=z9hG4bKessaireply\r\n'
    'Max-Forwards: 70\r\n'
    'From: <sip:200@192.0.2.2>;tag=appelant\r\n'
    'To: <sip:100@192.0.2.1>;tag=appele\r\n'
    'Call-ID: essai-reply-motif\r\n'
    'CSeq: 2 BYE\r\n'
    'Content-Length: 0\r\n'
    '\r\n';

IncomingRequest _requete(_TransactionTemoin transaction) {
  final IncomingRequest requete = parseMessage(bye, null) as IncomingRequest;
  requete.server_transaction = transaction;
  return requete;
}

List<void Function()> testFunctions = <void Function()>[
  () => test('reply: un motif fourni part dans la ligne de statut.', () {
        final _TransactionTemoin transaction = _TransactionTemoin();
        _requete(transaction).reply(403, 'Wrong Status');
        expect(transaction.code, 403);
        expect(transaction.reponse, startsWith('SIP/2.0 403 Wrong Status\r\n'));
      }),
  () => test('reply: sans motif, celui du code est utilisé.', () {
        final _TransactionTemoin transaction = _TransactionTemoin();
        _requete(transaction).reply(481);
        expect(transaction.reponse,
            startsWith('SIP/2.0 481 Call/Transaction Does Not Exist\r\n'));
      }),
  () => test('reply: un code hors 100-699 est toujours refusé.', () {
        final _TransactionTemoin transaction = _TransactionTemoin();
        expect(() => _requete(transaction).reply(99, 'Trop bas'),
            throwsA(anything));
        expect(transaction.code, isNull);
      }),
];

void main() {
  for (final void Function() f in testFunctions) {
    f();
  }
}
