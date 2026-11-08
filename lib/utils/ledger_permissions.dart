import '../data/db.dart';

bool canWriteLedger(Ledger? ledger) => ledger != null &&
    (!ledger.isShared || const {'owner', 'editor'}.contains(ledger.myRole));
