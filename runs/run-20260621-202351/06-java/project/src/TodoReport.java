import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public class TodoReport {
  enum Type {
    UNDEFINED, NULL, BOOL, NUMBER, STRING, ARRAY, OBJECT
  }

  static final class Value {
    Type type = Type.UNDEFINED;
    boolean bool;
    double number;
    String string = "";
    List<Value> array = new ArrayList<>();
    List<Field> object = new ArrayList<>();

    static Value undefined() {
      return new Value();
    }

    static Value nullValue() {
      Value value = new Value();
      value.type = Type.NULL;
      return value;
    }

    static Value boolValue(boolean b) {
      Value value = new Value();
      value.type = Type.BOOL;
      value.bool = b;
      return value;
    }

    static Value numberValue(double n) {
      Value value = new Value();
      value.type = Type.NUMBER;
      value.number = n;
      return value;
    }

    static Value stringValue(String s) {
      Value value = new Value();
      value.type = Type.STRING;
      value.string = s;
      return value;
    }

    static Value arrayValue(List<Value> values) {
      Value value = new Value();
      value.type = Type.ARRAY;
      value.array = values;
      return value;
    }

    static Value objectValue(List<Field> fields) {
      Value value = new Value();
      value.type = Type.OBJECT;
      value.object = fields;
      return value;
    }
  }

  static final class Field {
    final String key;
    Value value;

    Field(String key, Value value) {
      this.key = key;
      this.value = value;
    }
  }

  static final class JsonParser {
    final String text;
    int pos;

    JsonParser(String text) {
      this.text = text;
    }

    Value parse() {
      skipWs();
      Value value = parseValue();
      skipWs();
      if (pos != text.length()) {
        throw new RuntimeException("unexpected token at '" + text.substring(pos, pos + 1) + "'");
      }
      return value;
    }

    void skipWs() {
      while (pos < text.length()) {
        char c = text.charAt(pos);
        if (c != ' ' && c != '\n' && c != '\r' && c != '\t') {
          break;
        }
        pos++;
      }
    }

    char peek() {
      if (pos >= text.length()) {
        throw new RuntimeException("unexpected end of input");
      }
      return text.charAt(pos);
    }

    boolean consume(char c) {
      if (pos < text.length() && text.charAt(pos) == c) {
        pos++;
        return true;
      }
      return false;
    }

    void expect(char c) {
      if (!consume(c)) {
        throw new RuntimeException("expected '" + c + "'");
      }
    }

    Value parseValue() {
      skipWs();
      char c = peek();
      if (c == 'n') {
        literal("null");
        return Value.nullValue();
      }
      if (c == 't') {
        literal("true");
        return Value.boolValue(true);
      }
      if (c == 'f') {
        literal("false");
        return Value.boolValue(false);
      }
      if (c == '"') {
        return Value.stringValue(parseString());
      }
      if (c == '[') {
        return parseArray();
      }
      if (c == '{') {
        return parseObject();
      }
      return parseNumber();
    }

    void literal(String word) {
      if (!text.startsWith(word, pos)) {
        throw new RuntimeException("unexpected token");
      }
      pos += word.length();
    }

    int parseHex4() {
      if (pos + 4 > text.length()) {
        throw new RuntimeException("invalid unicode escape");
      }
      int cp = 0;
      for (int i = 0; i < 4; i++) {
        char c = text.charAt(pos++);
        cp <<= 4;
        if (c >= '0' && c <= '9') {
          cp += c - '0';
        } else if (c >= 'a' && c <= 'f') {
          cp += c - 'a' + 10;
        } else if (c >= 'A' && c <= 'F') {
          cp += c - 'A' + 10;
        } else {
          throw new RuntimeException("invalid unicode escape");
        }
      }
      return cp;
    }

    String parseString() {
      expect('"');
      StringBuilder out = new StringBuilder();
      while (pos < text.length()) {
        char c = text.charAt(pos++);
        if (c == '"') {
          return out.toString();
        }
        if (c < 0x20) {
          throw new RuntimeException("control character in string");
        }
        if (c != '\\') {
          out.append(c);
          continue;
        }
        if (pos >= text.length()) {
          throw new RuntimeException("invalid escape");
        }
        char esc = text.charAt(pos++);
        switch (esc) {
          case '"':
          case '\\':
          case '/':
            out.append(esc);
            break;
          case 'b':
            out.append('\b');
            break;
          case 'f':
            out.append('\f');
            break;
          case 'n':
            out.append('\n');
            break;
          case 'r':
            out.append('\r');
            break;
          case 't':
            out.append('\t');
            break;
          case 'u':
            int cp = parseHex4();
            if (cp >= 0xD800 && cp <= 0xDBFF) {
              if (pos + 6 > text.length() || text.charAt(pos) != '\\' || text.charAt(pos + 1) != 'u') {
                throw new RuntimeException("invalid unicode surrogate");
              }
              pos += 2;
              int low = parseHex4();
              if (low < 0xDC00 || low > 0xDFFF) {
                throw new RuntimeException("invalid unicode surrogate");
              }
              cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
            }
            out.appendCodePoint(cp);
            break;
          default:
            throw new RuntimeException("invalid escape");
        }
      }
      throw new RuntimeException("unterminated string");
    }

    Value parseNumber() {
      int begin = pos;
      if (pos < text.length() && (text.charAt(pos) == '+' || text.charAt(pos) == '-')) {
        pos++;
      }
      while (pos < text.length() && Character.isDigit(text.charAt(pos))) {
        pos++;
      }
      if (pos < text.length() && text.charAt(pos) == '.') {
        pos++;
        while (pos < text.length() && Character.isDigit(text.charAt(pos))) {
          pos++;
        }
      }
      if (pos < text.length() && (text.charAt(pos) == 'e' || text.charAt(pos) == 'E')) {
        int save = pos++;
        if (pos < text.length() && (text.charAt(pos) == '+' || text.charAt(pos) == '-')) {
          pos++;
        }
        int expBegin = pos;
        while (pos < text.length() && Character.isDigit(text.charAt(pos))) {
          pos++;
        }
        if (expBegin == pos) {
          pos = save;
        }
      }
      if (begin == pos || (pos == begin + 1 && (text.charAt(begin) == '+' || text.charAt(begin) == '-'))) {
        throw new RuntimeException("unexpected token");
      }
      return Value.numberValue(Double.parseDouble(text.substring(begin, pos)));
    }

    Value parseArray() {
      expect('[');
      skipWs();
      List<Value> values = new ArrayList<>();
      if (consume(']')) {
        return Value.arrayValue(values);
      }
      while (true) {
        values.add(parseValue());
        skipWs();
        if (consume(']')) {
          break;
        }
        expect(',');
      }
      return Value.arrayValue(values);
    }

    Value parseObject() {
      expect('{');
      skipWs();
      List<Field> fields = new ArrayList<>();
      if (consume('}')) {
        return Value.objectValue(fields);
      }
      while (true) {
        skipWs();
        String key = parseString();
        skipWs();
        expect(':');
        Value value = parseValue();
        Field existing = null;
        for (Field field : fields) {
          if (field.key.equals(key)) {
            existing = field;
            break;
          }
        }
        if (existing == null) {
          fields.add(new Field(key, value));
        } else {
          existing.value = value;
        }
        skipWs();
        if (consume('}')) {
          break;
        }
        expect(',');
      }
      return Value.objectValue(fields);
    }
  }

  static String jsonStringEscape(String s) {
    StringBuilder out = new StringBuilder();
    out.append('"');
    for (int i = 0; i < s.length(); ) {
      int cp = s.codePointAt(i);
      i += Character.charCount(cp);
      switch (cp) {
        case '"':
          out.append("\\\"");
          break;
        case '\\':
          out.append("\\\\");
          break;
        case '\b':
          out.append("\\b");
          break;
        case '\f':
          out.append("\\f");
          break;
        case '\n':
          out.append("\\n");
          break;
        case '\r':
          out.append("\\r");
          break;
        case '\t':
          out.append("\\t");
          break;
        default:
          if (cp < 0x20) {
            out.append(String.format("\\u%04x", cp));
          } else {
            out.appendCodePoint(cp);
          }
      }
    }
    out.append('"');
    return out.toString();
  }

  static boolean numberIsInteger(double n) {
    return Double.isFinite(n) && Math.floor(n) == n && n >= Long.MIN_VALUE && n <= Long.MAX_VALUE;
  }

  static String numberToString(double n) {
    if (numberIsInteger(n)) {
      return Long.toString((long) n);
    }
    return String.format(java.util.Locale.ROOT, "%.15g", n);
  }

  static String jsString(Value value) {
    switch (value.type) {
      case UNDEFINED:
        return "undefined";
      case NULL:
        return "null";
      case BOOL:
        return value.bool ? "true" : "false";
      case STRING:
        return value.string;
      case NUMBER:
        return numberToString(value.number);
      case ARRAY:
      case OBJECT:
        return pyRepr(value);
      default:
        return "";
    }
  }

  static String pyListStr(List<Value> values) {
    StringBuilder out = new StringBuilder("[");
    for (int i = 0; i < values.size(); i++) {
      if (i != 0) {
        out.append(", ");
      }
      out.append(pyRepr(values.get(i)));
    }
    out.append("]");
    return out.toString();
  }

  static String pyHashStr(List<Field> fields) {
    StringBuilder out = new StringBuilder("{");
    for (int i = 0; i < fields.size(); i++) {
      if (i != 0) {
        out.append(", ");
      }
      out.append(pyRepr(Value.stringValue(fields.get(i).key)));
      out.append(": ");
      out.append(pyRepr(fields.get(i).value));
    }
    out.append("}");
    return out.toString();
  }

  static String pyRepr(Value value) {
    switch (value.type) {
      case UNDEFINED:
        return "undefined";
      case NULL:
        return "None";
      case BOOL:
        return value.bool ? "True" : "False";
      case NUMBER:
        return numberToString(value.number);
      case STRING:
        return jsonStringEscape(value.string);
      case ARRAY:
        return pyListStr(value.array);
      case OBJECT:
        return pyHashStr(value.object);
      default:
        return "";
    }
  }

  static String pyStr(Value value) {
    switch (value.type) {
      case NULL:
        return "None";
      case BOOL:
        return value.bool ? "True" : "False";
      case ARRAY:
        return pyListStr(value.array);
      case OBJECT:
        return pyHashStr(value.object);
      default:
        return jsString(value);
    }
  }

  static String jsJsonStringify(Value value) {
    switch (value.type) {
      case UNDEFINED:
        return "undefined";
      case NULL:
        return "null";
      case BOOL:
        return value.bool ? "true" : "false";
      case NUMBER:
        return numberToString(value.number);
      case STRING:
        return jsonStringEscape(value.string);
      case ARRAY:
        StringBuilder array = new StringBuilder("[");
        for (int i = 0; i < value.array.size(); i++) {
          if (i != 0) {
            array.append(',');
          }
          array.append(jsJsonStringify(value.array.get(i)));
        }
        array.append(']');
        return array.toString();
      case OBJECT:
        StringBuilder object = new StringBuilder("{");
        for (int i = 0; i < value.object.size(); i++) {
          if (i != 0) {
            object.append(',');
          }
          object.append(jsonStringEscape(value.object.get(i).key));
          object.append(':');
          object.append(jsJsonStringify(value.object.get(i).value));
        }
        object.append('}');
        return object.toString();
      default:
        return "";
    }
  }

  static boolean pythonTruthy(Value value) {
    switch (value.type) {
      case UNDEFINED:
        return true;
      case NULL:
        return false;
      case BOOL:
        return value.bool;
      case NUMBER:
        return value.number != 0.0;
      case STRING:
        return !value.string.isEmpty();
      case ARRAY:
        return !value.array.isEmpty();
      case OBJECT:
        return !value.object.isEmpty();
      default:
        return true;
    }
  }

  static Value objectGet(Value object, String key) {
    if (object.type != Type.OBJECT) {
      return null;
    }
    for (Field field : object.object) {
      if (field.key.equals(key)) {
        return field.value;
      }
    }
    return null;
  }

  static LocalDate parseDateOnly(Value value) {
    String text = jsString(value);
    boolean shape = text.length() == 10
        && Character.isDigit(text.charAt(0))
        && Character.isDigit(text.charAt(1))
        && Character.isDigit(text.charAt(2))
        && Character.isDigit(text.charAt(3))
        && text.charAt(4) == '-'
        && Character.isDigit(text.charAt(5))
        && Character.isDigit(text.charAt(6))
        && text.charAt(7) == '-'
        && Character.isDigit(text.charAt(8))
        && Character.isDigit(text.charAt(9));
    if (!shape) {
      throw new RuntimeException("parsing time " + jsJsonStringify(value) + " as \"2006-01-02\": cannot parse date");
    }

    int year = Integer.parseInt(text.substring(0, 4));
    int month = Integer.parseInt(text.substring(5, 7));
    int day = Integer.parseInt(text.substring(8, 10));
    if ((year >= 0 && year <= 99) || month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)) {
      throw new RuntimeException("parsing time " + jsJsonStringify(value) + ": day out of range");
    }
    return LocalDate.of(year, month, day);
  }

  static boolean leapYear(int y) {
    return (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
  }

  static int daysInMonth(int y, int m) {
    int[] days = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (m == 2) {
      return leapYear(y) ? 29 : 28;
    }
    if (m < 1 || m > 12) {
      return 0;
    }
    return days[m - 1];
  }

  static String canonicalKey(Value value) {
    return jsJsonStringify(value);
  }

  static final class Summary {
    final Value userId;
    int completed;
    int missed;

    Summary(Value userId) {
      this.userId = userId;
    }
  }

  static final class PyKey {
    int group;
    double number;
    String text;

    PyKey(int group, double number, String text) {
      this.group = group;
      this.number = number;
      this.text = text;
    }
  }

  static PyKey pyKey(Value value) {
    switch (value.type) {
      case NULL:
        return new PyKey(0, 0.0, "");
      case BOOL:
        return new PyKey(1, value.bool ? 1.0 : 0.0, "");
      case NUMBER:
        return new PyKey(1, value.number, "");
      case STRING:
        return new PyKey(2, 0.0, value.string);
      default:
        return new PyKey(3, 0.0, jsString(value));
    }
  }

  static int pyKeyCompare(Value a, Value b) {
    PyKey ka = pyKey(a);
    PyKey kb = pyKey(b);
    if (ka.group != kb.group) {
      return Integer.compare(ka.group, kb.group);
    }
    if (ka.group == 1 && ka.number != kb.number) {
      return Double.compare(ka.number, kb.number);
    }
    return ka.text.compareTo(kb.text);
  }

  static String ljust(String s, int width) {
    if (s.length() >= width) {
      return s;
    }
    return s + " ".repeat(width - s.length());
  }

  static Value fetchJson(String urlText) throws IOException {
    HttpURLConnection conn = (HttpURLConnection) new URL(urlText).openConnection();
    conn.setInstanceFollowRedirects(false);
    conn.setConnectTimeout(10_000);
    conn.setReadTimeout(10_000);

    int code = conn.getResponseCode();
    String reason = conn.getResponseMessage();
    InputStream stream = code >= 200 && code < 300 ? conn.getInputStream() : conn.getErrorStream();
    byte[] bytes = stream == null ? new byte[0] : stream.readAllBytes();
    conn.disconnect();

    if (code < 200 || code >= 300) {
      String rendered = Integer.toString(code);
      if (reason != null && !reason.isEmpty()) {
        rendered += " " + reason;
      }
      System.err.println("bad status: " + rendered);
      System.exit(1);
    }

    String body = new String(bytes, StandardCharsets.UTF_8);
    return new JsonParser(body).parse();
  }

  static void usage(String program) {
    System.err.println("usage: " + program + " <todos-url>");
    System.exit(1);
  }

  public static void main(String[] args) {
    if (args.length != 1) {
      usage("TodoReport");
    }

    try {
      Value todos = fetchJson(args[0]);
      LocalDate today = LocalDate.now();
      Map<String, Summary> byUser = new LinkedHashMap<>();
      List<String> insertionOrder = new ArrayList<>();

      if (todos.type == Type.ARRAY) {
        for (Value todo : todos.array) {
          Value userField = objectGet(todo, "userId");
          Value userId = userField == null ? Value.undefined() : userField;
          String key = canonicalKey(userId);
          Summary summary = byUser.get(key);
          if (summary == null) {
            insertionOrder.add(key);
            summary = new Summary(userId);
            byUser.put(key, summary);
          }

          Value completedField = objectGet(todo, "completed");
          Value completed = completedField == null ? Value.undefined() : completedField;
          if (pythonTruthy(completed)) {
            summary.completed++;
          } else {
            Value dueField = objectGet(todo, "dueDate");
            Value dueValue = dueField == null ? Value.undefined() : dueField;
            LocalDate due = parseDateOnly(dueValue);
            if (due.isBefore(today)) {
              summary.missed++;
            }
          }
        }
      }

      List<Summary> rows = new ArrayList<>();
      for (String key : insertionOrder) {
        rows.add(byUser.get(key));
      }

      rows.sort((a, b) -> {
        if (a.completed != b.completed) {
          return Integer.compare(b.completed, a.completed);
        }
        if (a.missed != b.missed) {
          return Integer.compare(b.missed, a.missed);
        }
        return pyKeyCompare(a.userId, b.userId);
      });

      StringBuilder out = new StringBuilder();
      out.append("USER  COMPLETED  MISSED\n");
      for (Summary summary : rows) {
        out.append(ljust(pyStr(summary.userId), 5))
            .append(' ')
            .append(ljust(Integer.toString(summary.completed), 10))
            .append(' ')
            .append(summary.missed)
            .append('\n');
      }
      System.out.print(out.toString());
    } catch (Exception e) {
      System.err.println(e.getMessage());
      System.exit(1);
    }
  }
}
