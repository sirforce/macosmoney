import com.healthmarketscience.jackcess.Database;
import com.healthmarketscience.jackcess.DatabaseBuilder;
import com.healthmarketscience.jackcess.Row;
import com.healthmarketscience.jackcess.crypt.CryptCodecProvider;

import java.io.*;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.Instant;
import java.util.*;

/**
 * Read-only converter from a Microsoft Money (2005 – Sunset) .mny file to a neutral JSON document.
 *
 * All knowledge of Money's internal schema lives here, so the Mac app only ever sees clean data.
 * The .mny file is opened read-only and is never modified.
 *
 * Usage: java -jar mny-export.jar <file.mny> <out.json> [password]
 *
 * Money schema notes (verified against a real Sunset Edition file):
 *  - TRN.frq == -1 is a real register entry; anything else is a scheduled-bill template.
 *  - TRN.grftt bit 0x100 = void, 0x20 = split parent, 0x02 = transfer, 0x200000 = bill template.
 *  - TRN.cs: 0 = uncleared, 1 = cleared, 2 = reconciled.
 *  - TRN_SPLIT(htrn -> htrnParent): the parent carries the full amount, children carry the pieces.
 *  - TRN_XFER(htrnFrom, htrnLink): the two sides of a transfer.
 *  - TRN.szId: first char is a type prefix ('0' = check number, '1' = text code like ATM/Debit).
 *  - BILL rows are versions of a series (hbillHead). The head row's iinstNextUnpaid is the next
 *    occurrence; the series is finished when that reaches cInstMax (>= 0) or passes dtMax.
 *  - BILL.frq: 0 once, 2 weekly (cFrqInst = occurrences per week), 3 monthly (cFrqInst 2 = twice
 *    a month), 4 quarterly, 5 yearly (cFrqInst = occurrences per year).
 *  - XBAG rows with tbl = -4036 (TRN), bt = 0, grf = 1 are register flags (lHobj = htrn), with an
 *    optional comment (szMemo) and action date (dtFollowup). Money keeps them after reconciling; the
 *    app decides whether to show them.
 *  - Dates in year >= 2200 are "no date" sentinels.
 */
public class MnyExport {
    static final int GRFTT_TRANSFER = 0x2, GRFTT_SPLIT_PARENT = 0x20, GRFTT_VOID = 0x100;

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: java -jar mny-export.jar <file.mny> <out.json> [password]");
            System.exit(2);
        }
        File in = new File(args[0]);
        String password = args.length > 2 ? args[2] : null;
        try (Database db = new DatabaseBuilder(in).setReadOnly(true)
                .setCodecProvider(new CryptCodecProvider(password)).open();
             Writer w = new BufferedWriter(new OutputStreamWriter(new FileOutputStream(args[1]), StandardCharsets.UTF_8))) {
            new MnyExport(db, in).write(new Json(w));
        }
    }

    final Database db;
    final File file;
    final Map<Integer, Row> trn = new HashMap<>();
    final Map<Integer, Integer> splitParentOf = new HashMap<>();
    final Map<Integer, List<Integer>> splitChildren = new HashMap<>();
    final Map<Integer, Integer> transferPeer = new HashMap<>();
    final Set<Integer> postedBillSeries = new HashSet<>();
    final Map<Integer, Integer> splitOrder = new HashMap<>();
    final Map<Integer, Row> flagged = new HashMap<>();
    static final int XBAG_TBL_TRN = -4036;

    MnyExport(Database db, File file) throws IOException {
        this.db = db;
        this.file = file;
        for (Row r : db.getTable("TRN")) {
            trn.put(r.getInt("htrn"), r);
            Integer billHead = positive(r.getInt("hbillHead"));
            if (billHead != null && isRegisterEntry(r)) postedBillSeries.add(billHead);
        }
        for (Row r : db.getTable("TRN_SPLIT")) {
            splitParentOf.put(r.getInt("htrn"), r.getInt("htrnParent"));
            splitOrder.put(r.getInt("htrn"), intOr(r.getInt("iSplit"), 0));
            splitChildren.computeIfAbsent(r.getInt("htrnParent"), k -> new ArrayList<>()).add(r.getInt("htrn"));
        }
        for (List<Integer> kids : splitChildren.values()) kids.sort(Comparator.comparing(splitOrder::get));
        if (db.getTableNames().contains("XBAG")) {
            for (Row r : db.getTable("XBAG")) {
                if (intOr(r.getInt("tbl"), 0) == XBAG_TBL_TRN && intOr(r.getInt("bt"), -1) == 0 && intOr(r.getInt("grf"), 0) == 1)
                    flagged.put(r.getInt("lHobj"), r);
            }
        }
        for (Row r : db.getTable("TRN_XFER")) {
            transferPeer.put(r.getInt("htrnFrom"), r.getInt("htrnLink"));
            transferPeer.put(r.getInt("htrnLink"), r.getInt("htrnFrom"));
        }
    }

    void write(Json j) throws Exception {
        j.beginObject();
        j.key("format").value("macmoney-export");
        j.key("version").value(1);
        j.key("exportedAt").value(Instant.now().toString());
        writeSource(j);
        writeAccounts(j);
        writeCategories(j);
        writePayees(j);
        writeTransactions(j);
        writeBills(j);
        j.endObject();
        j.flush();
    }

    void writeSource(Json j) throws Exception {
        MessageDigest sha = MessageDigest.getInstance("SHA-256");
        try (InputStream is = Files.newInputStream(file.toPath())) {
            byte[] buf = new byte[1 << 16];
            for (int n; (n = is.read(buf)) > 0; ) sha.update(buf, 0, n);
        }
        StringBuilder hex = new StringBuilder();
        for (byte b : sha.digest()) hex.append(String.format("%02x", b));
        j.key("source").beginObject();
        j.key("fileName").value(file.getName());
        j.key("fileSize").value(file.length());
        j.key("modified").value(Instant.ofEpochMilli(file.lastModified()).toString());
        j.key("sha256").value(hex.toString());
        j.endObject();
    }

    void writeAccounts(Json j) throws IOException {
        j.key("accounts").beginArray();
        for (Row r : db.getTable("ACCT")) {
            j.beginObject();
            j.key("moneyId").value(r.getInt("hacct"));
            j.key("name").value(r.getString("szFull"));
            j.key("kind").value(accountKind(r.getInt("at")));
            j.key("closed").value(Boolean.TRUE.equals(r.getBoolean("fClosed")));
            j.key("openingBalance").value(money(r.getBigDecimal("amtOpen")));
            j.key("openDate").value(date(r.getLocalDateTime("dtOpen")));
            j.key("lastReconciledDate").value(date(r.getLocalDateTime("dtEndRec")));
            j.key("lastReconciledBalance").value(money(r.getBigDecimal("amtEndRec")));
            j.key("accountNumber").value(r.getString("mNum"));
            j.key("comment").value(r.getString("mComment"));
            j.key("isBusiness").value(Boolean.TRUE.equals(r.getBoolean("fBusiness")));
            j.endObject();
        }
        j.endArray();
    }

    static String accountKind(Integer at) {
        if (at == null) return "other";
        switch (at) {
            case 0: return "bank";
            case 1: return "creditCard";
            case 5: return "investment";
            case 6: return "loan";
            default: return "other";
        }
    }

    void writeCategories(Json j) throws IOException {
        Map<Integer, Row> cats = new HashMap<>();
        for (Row r : db.getTable("CAT")) cats.put(r.getInt("hcat"), r);
        j.key("categories").beginArray();
        for (Row r : cats.values()) {
            // Walk to the root ("Income" / "Expense") to classify.
            Row root = r;
            for (int guard = 0; guard < 10 && root.getInt("hcatParent") != null && cats.containsKey(root.getInt("hcatParent")); guard++)
                root = cats.get(root.getInt("hcatParent"));
            String rootName = root.getString("szFull") == null ? "" : root.getString("szFull").toLowerCase(Locale.ROOT);
            j.beginObject();
            j.key("moneyId").value(r.getInt("hcat"));
            Integer parent = r.getInt("hcatParent");
            j.key("parentId").value(parent != null && cats.containsKey(parent) ? parent : null);
            j.key("name").value(r.getString("szFull"));
            j.key("level").value(r.getInt("nLevel"));
            j.key("kind").value(rootName.contains("income") ? "income" : "expense");
            j.key("isTaxRelated").value(Boolean.TRUE.equals(r.getBoolean("fTax")));
            j.key("isBusiness").value(Boolean.TRUE.equals(r.getBoolean("fBusiness")));
            j.key("hidden").value(Boolean.TRUE.equals(r.getBoolean("fHidden")));
            j.key("comment").value(r.getString("mComment"));
            j.endObject();
        }
        j.endArray();
    }

    void writePayees(Json j) throws IOException {
        j.key("payees").beginArray();
        for (Row r : db.getTable("PAY")) {
            j.beginObject();
            j.key("moneyId").value(r.getInt("hpay"));
            Integer parent = r.getInt("hpayParent");
            j.key("parentId").value(parent != null && parent > 0 ? parent : null);
            j.key("name").value(r.getString("szFull"));
            j.key("hidden").value(Boolean.TRUE.equals(r.getBoolean("fHidden")));
            j.key("accountNumber").value(r.getString("mAcctNum"));
            j.key("website").value(r.getString("mWebPage"));
            j.key("comment").value(r.getString("mComment"));
            j.endObject();
        }
        j.endArray();
    }

    void writeTransactions(Json j) throws IOException {
        List<Row> rows = new ArrayList<>();
        for (Row r : trn.values()) if (isRegisterEntry(r)) rows.add(r);
        rows.sort(Comparator.comparing((Row r) -> r.getLocalDateTime("dt")).thenComparing(r -> r.getInt("htrn")));
        j.key("transactions").beginArray();
        for (Row r : rows) {
            int id = r.getInt("htrn");
            int flags = intOr(r.getInt("grftt"), 0);
            Integer peer = transferPeer.get(id);
            j.beginObject();
            j.key("moneyId").value(id);
            j.key("accountId").value(r.getInt("hacct"));
            j.key("date").value(date(r.getLocalDateTime("dt")));
            j.key("amount").value(money(r.getBigDecimal("amt")));
            j.key("number").value(checkNumber(r.getString("szId")));
            j.key("payeeId").value(positive(r.getInt("lHpay")));
            j.key("categoryId").value(positive(r.getInt("hcat")));
            j.key("memo").value(blankToNull(r.getString("mMemo")));
            j.key("status").value(status(r.getInt("cs")));
            j.key("dateCleared").value(date(r.getLocalDateTime("dtCleared")));
            j.key("isVoid").value((flags & GRFTT_VOID) != 0);
            Row flag = flagged.get(id);
            j.key("flagged").value(flag != null);
            j.key("flagNote").value(flag == null ? null : blankToNull(flag.getString("szMemo") != null ? flag.getString("szMemo") : flag.getString("mMemo")));
            j.key("flagDate").value(flag == null ? null : date(flag.getLocalDateTime("dtFollowup")));
            j.key("splitParentId").value(splitParentOf.get(id));
            j.key("splitOrder").value(splitOrder.get(id));
            j.key("isSplitParent").value(splitChildren.containsKey(id));
            j.key("transferPeerId").value(peer);
            j.key("transferAccountId").value(peer != null ? positive(r.getInt("hacctLink")) : null);
            Integer billHead = positive(r.getInt("hbillHead"));
            j.key("billSeriesId").value(billHead);
            j.key("billOccurrence").value(billHead != null && intOr(r.getInt("iinst"), -1) >= 0 ? r.getInt("iinst") : null);
            j.endObject();
        }
        j.endArray();
    }

    static boolean isRegisterEntry(Row r) {
        return intOr(r.getInt("frq"), -1) == -1 && r.getLocalDateTime("dt") != null;
    }

    void writeBills(Json j) throws IOException {
        Map<Integer, List<Row>> series = new TreeMap<>();
        for (Row b : db.getTable("BILL")) series.computeIfAbsent(b.getInt("hbillHead"), k -> new ArrayList<>()).add(b);
        j.key("bills").beginArray();
        for (Map.Entry<Integer, List<Row>> e : series.entrySet()) {
            List<Row> versions = e.getValue();
            versions.sort(Comparator.comparing(v -> intOr(v.getInt("iinst"), 0)));
            Row head = versions.stream().filter(v -> e.getKey().equals(v.getInt("hbill"))).findFirst().orElse(versions.get(0));
            int next = intOr(head.getInt("iinstNextUnpaid"), 0);
            // The version in effect for the next occurrence.
            Row current = versions.get(0);
            for (Row v : versions) if (intOr(v.getInt("iinst"), 0) <= next) current = v;
            Row t = trn.get(current.getInt("lHtrn"));
            if (t == null) continue;

            int frq = intOr(current.getInt("frq"), 0);
            double perPeriod = current.getDouble("cFrqInst") == null ? 1.0 : current.getDouble("cFrqInst");
            LocalDate base = current.getLocalDateTime("dt").toLocalDate();
            LocalDate nextDue = advance(base, frq, perPeriod, Math.max(0, next - intOr(current.getInt("iinst"), 0)));
            int maxCount = intOr(head.getInt("cInstMax"), -1);
            LocalDate endDate = dateOrNull(current.getLocalDateTime("dtMax"));
            // One-time bills don't advance the counter when paid; treat them as done once posted or past due.
            boolean finished = (maxCount >= 0 && next >= maxCount)
                    || (endDate != null && nextDue.isAfter(endDate))
                    || (frq == 0 && (postedBillSeries.contains(e.getKey()) || nextDue.isBefore(LocalDate.now())));

            int tid = t.getInt("htrn");
            j.beginObject();
            j.key("seriesId").value(e.getKey());
            j.key("accountId").value(t.getInt("hacct"));
            j.key("payeeId").value(positive(t.getInt("lHpay")));
            j.key("categoryId").value(positive(t.getInt("hcat")));
            j.key("amount").value(money(t.getBigDecimal("amt")));
            j.key("memo").value(blankToNull(t.getString("mMemo")));
            j.key("number").value(checkNumber(t.getString("szId")));
            j.key("transferAccountId").value((intOr(t.getInt("grftt"), 0) & GRFTT_TRANSFER) != 0 ? positive(t.getInt("hacctLink")) : null);
            j.key("frequency").beginObject();
            writeFrequency(j, frq, perPeriod);
            j.endObject();
            j.key("startDate").value(date(versions.get(0).getLocalDateTime("dt")));
            j.key("nextDue").value(nextDue.toString());
            j.key("nextOccurrence").value(next);
            j.key("maxOccurrences").value(maxCount >= 0 ? maxCount : null);
            j.key("endDate").value(endDate == null ? null : endDate.toString());
            j.key("moneyStatus").value(head.getInt("st"));
            j.key("finished").value(finished);
            j.key("splits").beginArray();
            for (int kid : splitChildren.getOrDefault(tid, Collections.emptyList())) {
                Row k = trn.get(kid);
                if (k == null) continue;
                j.beginObject();
                j.key("categoryId").value(positive(k.getInt("hcat")));
                j.key("amount").value(money(k.getBigDecimal("amt")));
                j.key("memo").value(blankToNull(k.getString("mMemo")));
                j.endObject();
            }
            j.endArray();
            j.endObject();
        }
        j.endArray();
    }

    static void writeFrequency(Json j, int frq, double perPeriod) throws IOException {
        switch (frq) {
            case 0: j.key("unit").value("once"); j.key("every").value(1); break;
            case 2:
                if (perPeriod >= 1) { j.key("unit").value("week"); j.key("every").value(1); }
                else { j.key("unit").value("week"); j.key("every").value(Math.round(1 / perPeriod)); }
                break;
            case 3:
                if (perPeriod >= 2) { j.key("unit").value("semimonth"); j.key("every").value(1); }
                else { j.key("unit").value("month"); j.key("every").value(Math.round(1 / perPeriod)); }
                break;
            case 4: j.key("unit").value("month"); j.key("every").value(3); break;
            case 5:
                if (perPeriod >= 1) { j.key("unit").value("month"); j.key("every").value(Math.round(12 / perPeriod)); }
                else { j.key("unit").value("year"); j.key("every").value(Math.round(1 / perPeriod)); }
                break;
            default: j.key("unit").value("unknown"); j.key("every").value(1); j.key("moneyFrq").value(frq);
        }
    }

    static LocalDate advance(LocalDate d, int frq, double perPeriod, long n) {
        switch (frq) {
            case 2: return d.plusWeeks(Math.round(1 / perPeriod) * n);
            case 3: return perPeriod >= 2 ? d.plusDays(15L * n) : d.plusMonths(Math.round(1 / perPeriod) * n);
            case 4: return d.plusMonths(3L * n);
            case 5: return perPeriod >= 1 ? d.plusMonths(Math.round(12 / perPeriod) * n) : d.plusYears(Math.round(1 / perPeriod) * n);
            default: return d;
        }
    }

    // ---- value helpers ----

    static String status(Integer cs) {
        if (cs == null) return "uncleared";
        switch (cs) {
            case 1: return "cleared";
            case 2: return "reconciled";
            default: return "uncleared";
        }
    }

    static String checkNumber(String szId) {
        if (szId == null) return null;
        String s = szId.length() > 1 && (szId.charAt(0) == '0' || szId.charAt(0) == '1') ? szId.substring(1) : szId;
        s = s.trim();
        return s.isEmpty() ? null : s;
    }

    static String money(BigDecimal v) {
        return v == null ? null : v.setScale(2, RoundingMode.HALF_EVEN).toPlainString();
    }

    static LocalDate dateOrNull(LocalDateTime dt) {
        return dt == null || dt.getYear() >= 2200 || dt.getYear() < 1900 ? null : dt.toLocalDate();
    }

    static String date(LocalDateTime dt) {
        LocalDate d = dateOrNull(dt);
        return d == null ? null : d.toString();
    }

    static Integer positive(Integer v) {
        return v == null || v <= 0 ? null : v;
    }

    static int intOr(Integer v, int dflt) {
        return v == null ? dflt : v;
    }

    static String blankToNull(String s) {
        return s == null || s.trim().isEmpty() ? null : s;
    }

    /** Minimal streaming JSON writer (no dependencies). */
    static final class Json {
        private final Writer w;
        private final Deque<Boolean> first = new ArrayDeque<>();
        private boolean afterKey;

        Json(Writer w) { this.w = w; }

        private void sep() throws IOException {
            if (afterKey) { afterKey = false; return; }
            if (!first.isEmpty()) {
                if (first.peek()) { first.pop(); first.push(false); } else w.write(',');
            }
        }
        Json beginObject() throws IOException { sep(); w.write('{'); first.push(true); return this; }
        Json endObject() throws IOException { first.pop(); w.write('}'); return this; }
        Json beginArray() throws IOException { sep(); w.write("[\n"); first.push(true); return this; }
        Json endArray() throws IOException { first.pop(); w.write("\n]"); return this; }
        Json key(String k) throws IOException { sep(); str(k); w.write(':'); afterKey = true; return this; }
        Json value(String s) throws IOException { sep(); if (s == null) w.write("null"); else str(s); return this; }
        Json value(Number n) throws IOException { sep(); w.write(n == null ? "null" : n.toString()); return this; }
        Json value(boolean b) throws IOException { sep(); w.write(b ? "true" : "false"); return this; }
        void flush() throws IOException { w.flush(); }

        private void str(String s) throws IOException {
            w.write('"');
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '"': w.write("\\\""); break;
                    case '\\': w.write("\\\\"); break;
                    case '\n': w.write("\\n"); break;
                    case '\r': w.write("\\r"); break;
                    case '\t': w.write("\\t"); break;
                    default:
                        if (c < 0x20) w.write(String.format("\\u%04x", (int) c)); else w.write(c);
                }
            }
            w.write('"');
        }
    }
}
