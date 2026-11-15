import 'dart:async';
import 'dart:io';

import 'package:logger/logger.dart';

import 'package:sip_ua/src/logger.dart' as journal;
import 'package:sip_ua/src/socket_transport.dart';
import 'package:sip_ua/src/transports/socket_interface.dart';
import 'package:sip_ua/src/transports/web_socket.dart';
import 'package:test/test.dart';

/// Une socket que le réseau a rendue sourde est remplacée sous le même
/// transport : le UA n'apprend aucune coupure, ses transactions survivent.
void main() {
  late HttpServer serveur;
  late List<WebSocket> cote;
  late List<List<dynamic>> recuParServeur;
  late List<int> fermeesCoteServeur;
  late StreamController<void> nouvelleSocket;

  late SocketTransport transport;
  late int connexions;
  late int coupures;
  late List<String> recuParClient;
  late StreamController<void> connecte;

  // Le journal par défaut lit sa propre pile d'appel et bute sur un chemin
  // Windows accentué : un journal muet suffit ici.
  setUpAll(() => journal.logger = Logger(level: Level.off));

  setUp(() async {
    cote = <WebSocket>[];
    recuParServeur = <List<dynamic>>[];
    fermeesCoteServeur = <int>[];
    nouvelleSocket = StreamController<void>.broadcast();
    serveur = await HttpServer.bind('127.0.0.1', 0);
    serveur.listen((HttpRequest req) async {
      final WebSocket ws = await WebSocketTransformer.upgrade(req);
      final int n = cote.length;
      cote.add(ws);
      recuParServeur.add(<dynamic>[]);
      ws.listen((dynamic m) => recuParServeur[n].add(m),
          onDone: () => fermeesCoteServeur.add(n));
      nouvelleSocket.add(null);
    });

    connexions = 0;
    coupures = 0;
    recuParClient = <String>[];
    connecte = StreamController<void>.broadcast();
    transport = SocketTransport(<SIPUASocketInterface>[
      SIPUAWebSocket('ws://127.0.0.1:${serveur.port}/sip', messageDelay: 0)
    ]);
    transport.onconnecting = (SIPUASocketInterface? s, int? essais) {};
    transport.onconnect = (SocketTransport t) {
      connexions++;
      connecte.add(null);
    };
    transport.ondisconnect = (SIPUASocketInterface? s, dynamic cause) {
      coupures++;
    };
    transport.ondata = (SocketTransport t, String data) {
      recuParClient.add(data);
    };
  });

  tearDown(() async {
    transport.disconnect();
    await serveur.close(force: true);
  });

  Future<void> ouvrir(void Function() action) async {
    final Future<void> cotServeur = nouvelleSocket.stream.first;
    final Future<void> cotClient = connecte.stream.first;
    action();
    await Future.wait(<Future<void>>[cotServeur, cotClient])
        .timeout(const Duration(seconds: 5));
  }

  Future<void> attendre(bool Function() condition) async {
    final DateTime limite = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(limite)) fail('délai dépassé');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('relancerSocket ouvre une socket neuve sans signaler de coupure',
      () async {
    await ouvrir(transport.connect);
    expect(connexions, 1);

    await ouvrir(transport.relancerSocket);
    expect(connexions, 2);
    expect(cote.length, 2);
    expect(transport.isConnected(), isTrue);

    // L'ancienne est fermée, et sa fermeture ne remonte pas.
    await attendre(() => fermeesCoteServeur.contains(0));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(coupures, 0);
    expect(transport.isConnected(), isTrue);

    // Tout passe désormais par la neuve, dans les deux sens.
    expect(transport.send('INVITE'), isTrue);
    await attendre(() => recuParServeur[1].isNotEmpty);
    expect(recuParServeur[1], <dynamic>['INVITE']);
    cote[1].add('SIP/2.0 200 OK');
    await attendre(() => recuParClient.isNotEmpty);
    expect(recuParClient, <String>['SIP/2.0 200 OK']);
  });

  test('la socket neuve qui tombe reste signalée, elle', () async {
    await ouvrir(transport.connect);
    await ouvrir(transport.relancerSocket);
    await attendre(() => fermeesCoteServeur.contains(0));

    await cote[1].close();
    await attendre(() => coupures == 1);
    expect(transport.isConnected(), isFalse);
  });

  test('sans effet après une fermeture demandée', () async {
    await ouvrir(transport.connect);
    transport.disconnect();
    final int signalees = coupures;
    transport.relancerSocket();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cote.length, 1);
    expect(transport.isConnected(), isFalse);
    expect(coupures, signalees);
  });
}
