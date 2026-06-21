#include <curl/curl.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <ctime>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

struct Value {
  enum class Type { Undefined, Null, Bool, Number, String, Array, Object };

  Type type = Type::Undefined;
  bool boolean = false;
  double number = 0.0;
  std::string string;
  std::vector<Value> array;
  std::vector<std::pair<std::string, Value>> object;

  static Value undefined() { return Value{}; }
  static Value null() {
    Value v;
    v.type = Type::Null;
    return v;
  }
  static Value boolean_value(bool b) {
    Value v;
    v.type = Type::Bool;
    v.boolean = b;
    return v;
  }
  static Value number_value(double n) {
    Value v;
    v.type = Type::Number;
    v.number = n;
    return v;
  }
  static Value string_value(std::string s) {
    Value v;
    v.type = Type::String;
    v.string = std::move(s);
    return v;
  }
  static Value array_value(std::vector<Value> a) {
    Value v;
    v.type = Type::Array;
    v.array = std::move(a);
    return v;
  }
  static Value object_value(std::vector<std::pair<std::string, Value>> o) {
    Value v;
    v.type = Type::Object;
    v.object = std::move(o);
    return v;
  }
};

class JsonParser {
 public:
  explicit JsonParser(std::string text) : text_(std::move(text)) {}

  Value parse() {
    skip_ws();
    Value value = parse_value();
    skip_ws();
    if (pos_ != text_.size()) {
      throw std::runtime_error("unexpected token at '" + text_.substr(pos_, 1) + "'");
    }
    return value;
  }

 private:
  std::string text_;
  std::size_t pos_ = 0;

  void skip_ws() {
    while (pos_ < text_.size()) {
      unsigned char c = static_cast<unsigned char>(text_[pos_]);
      if (c != ' ' && c != '\n' && c != '\r' && c != '\t') {
        break;
      }
      ++pos_;
    }
  }

  char peek() const {
    if (pos_ >= text_.size()) {
      throw std::runtime_error("unexpected end of input");
    }
    return text_[pos_];
  }

  bool consume(char c) {
    if (pos_ < text_.size() && text_[pos_] == c) {
      ++pos_;
      return true;
    }
    return false;
  }

  void expect(char c) {
    if (!consume(c)) {
      throw std::runtime_error(std::string("expected '") + c + "'");
    }
  }

  Value parse_value() {
    skip_ws();
    char c = peek();
    if (c == 'n') {
      literal("null");
      return Value::null();
    }
    if (c == 't') {
      literal("true");
      return Value::boolean_value(true);
    }
    if (c == 'f') {
      literal("false");
      return Value::boolean_value(false);
    }
    if (c == '"') {
      return Value::string_value(parse_string());
    }
    if (c == '[') {
      return parse_array();
    }
    if (c == '{') {
      return parse_object();
    }
    return parse_number();
  }

  void literal(const char *word) {
    std::string w(word);
    if (text_.compare(pos_, w.size(), w) != 0) {
      throw std::runtime_error("unexpected token");
    }
    pos_ += w.size();
  }

  static void append_utf8(std::string &out, unsigned int cp) {
    if (cp <= 0x7F) {
      out.push_back(static_cast<char>(cp));
    } else if (cp <= 0x7FF) {
      out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp <= 0xFFFF) {
      out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
      out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
  }

  unsigned int parse_hex4() {
    if (pos_ + 4 > text_.size()) {
      throw std::runtime_error("invalid unicode escape");
    }
    unsigned int cp = 0;
    for (int i = 0; i < 4; ++i) {
      char c = text_[pos_++];
      cp <<= 4;
      if (c >= '0' && c <= '9') {
        cp += static_cast<unsigned int>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        cp += static_cast<unsigned int>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        cp += static_cast<unsigned int>(c - 'A' + 10);
      } else {
        throw std::runtime_error("invalid unicode escape");
      }
    }
    return cp;
  }

  std::string parse_string() {
    expect('"');
    std::string out;
    while (pos_ < text_.size()) {
      unsigned char c = static_cast<unsigned char>(text_[pos_++]);
      if (c == '"') {
        return out;
      }
      if (c < 0x20) {
        throw std::runtime_error("control character in string");
      }
      if (c != '\\') {
        out.push_back(static_cast<char>(c));
        continue;
      }
      if (pos_ >= text_.size()) {
        throw std::runtime_error("invalid escape");
      }
      char esc = text_[pos_++];
      switch (esc) {
        case '"':
        case '\\':
        case '/':
          out.push_back(esc);
          break;
        case 'b':
          out.push_back('\b');
          break;
        case 'f':
          out.push_back('\f');
          break;
        case 'n':
          out.push_back('\n');
          break;
        case 'r':
          out.push_back('\r');
          break;
        case 't':
          out.push_back('\t');
          break;
        case 'u': {
          unsigned int cp = parse_hex4();
          if (cp >= 0xD800 && cp <= 0xDBFF) {
            if (pos_ + 6 > text_.size() || text_[pos_] != '\\' || text_[pos_ + 1] != 'u') {
              throw std::runtime_error("invalid unicode surrogate");
            }
            pos_ += 2;
            unsigned int low = parse_hex4();
            if (low < 0xDC00 || low > 0xDFFF) {
              throw std::runtime_error("invalid unicode surrogate");
            }
            cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
          }
          append_utf8(out, cp);
          break;
        }
        default:
          throw std::runtime_error("invalid escape");
      }
    }
    throw std::runtime_error("unterminated string");
  }

  Value parse_number() {
    const char *begin = text_.c_str() + pos_;
    char *end = nullptr;
    double n = std::strtod(begin, &end);
    if (end == begin) {
      throw std::runtime_error("unexpected token");
    }
    pos_ += static_cast<std::size_t>(end - begin);
    return Value::number_value(n);
  }

  Value parse_array() {
    expect('[');
    skip_ws();
    std::vector<Value> values;
    if (consume(']')) {
      return Value::array_value(std::move(values));
    }
    while (true) {
      values.push_back(parse_value());
      skip_ws();
      if (consume(']')) {
        break;
      }
      expect(',');
    }
    return Value::array_value(std::move(values));
  }

  Value parse_object() {
    expect('{');
    skip_ws();
    std::vector<std::pair<std::string, Value>> fields;
    if (consume('}')) {
      return Value::object_value(std::move(fields));
    }
    while (true) {
      skip_ws();
      std::string key = parse_string();
      skip_ws();
      expect(':');
      Value value = parse_value();
      auto existing = std::find_if(fields.begin(), fields.end(), [&](const auto &field) { return field.first == key; });
      if (existing == fields.end()) {
        fields.emplace_back(std::move(key), std::move(value));
      } else {
        existing->second = std::move(value);
      }
      skip_ws();
      if (consume('}')) {
        break;
      }
      expect(',');
    }
    return Value::object_value(std::move(fields));
  }
};

std::string json_string_escape(const std::string &s) {
  std::ostringstream out;
  out << '"';
  for (unsigned char c : s) {
    switch (c) {
      case '"':
        out << "\\\"";
        break;
      case '\\':
        out << "\\\\";
        break;
      case '\b':
        out << "\\b";
        break;
      case '\f':
        out << "\\f";
        break;
      case '\n':
        out << "\\n";
        break;
      case '\r':
        out << "\\r";
        break;
      case '\t':
        out << "\\t";
        break;
      default:
        if (c < 0x20) {
          out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c)
              << std::dec << std::setfill(' ');
        } else {
          out << static_cast<char>(c);
        }
    }
  }
  out << '"';
  return out.str();
}

bool number_is_integer(double n) {
  return std::isfinite(n) && std::floor(n) == n &&
         n >= static_cast<double>(std::numeric_limits<long long>::min()) &&
         n <= static_cast<double>(std::numeric_limits<long long>::max());
}

std::string number_to_string(double n) {
  if (number_is_integer(n)) {
    return std::to_string(static_cast<long long>(n));
  }
  std::ostringstream out;
  out << std::setprecision(15) << n;
  return out.str();
}

std::string js_json_stringify(const Value &value);
std::string py_repr(const Value &value);

std::string js_string(const Value &value) {
  switch (value.type) {
    case Value::Type::Undefined:
      return "undefined";
    case Value::Type::Null:
      return "null";
    case Value::Type::Bool:
      return value.boolean ? "true" : "false";
    case Value::Type::String:
      return value.string;
    case Value::Type::Number:
      return number_to_string(value.number);
    case Value::Type::Array:
    case Value::Type::Object:
      return py_repr(value);
  }
  return "";
}

std::string py_list_str(const std::vector<Value> &values) {
  std::string out = "[";
  for (std::size_t i = 0; i < values.size(); ++i) {
    if (i != 0) {
      out += ", ";
    }
    out += py_repr(values[i]);
  }
  out += "]";
  return out;
}

std::string py_hash_str(const std::vector<std::pair<std::string, Value>> &values) {
  std::string out = "{";
  for (std::size_t i = 0; i < values.size(); ++i) {
    if (i != 0) {
      out += ", ";
    }
    out += py_repr(Value::string_value(values[i].first));
    out += ": ";
    out += py_repr(values[i].second);
  }
  out += "}";
  return out;
}

std::string py_repr(const Value &value) {
  switch (value.type) {
    case Value::Type::Undefined:
      return "undefined";
    case Value::Type::Null:
      return "None";
    case Value::Type::Bool:
      return value.boolean ? "True" : "False";
    case Value::Type::Number:
      return number_to_string(value.number);
    case Value::Type::String:
      return json_string_escape(value.string);
    case Value::Type::Array:
      return py_list_str(value.array);
    case Value::Type::Object:
      return py_hash_str(value.object);
  }
  return "";
}

std::string py_str(const Value &value) {
  switch (value.type) {
    case Value::Type::Null:
      return "None";
    case Value::Type::Bool:
      return value.boolean ? "True" : "False";
    case Value::Type::Array:
      return py_list_str(value.array);
    case Value::Type::Object:
      return py_hash_str(value.object);
    default:
      return js_string(value);
  }
}

std::string js_json_stringify(const Value &value) {
  switch (value.type) {
    case Value::Type::Undefined:
      return "undefined";
    case Value::Type::Null:
      return "null";
    case Value::Type::Bool:
      return value.boolean ? "true" : "false";
    case Value::Type::Number:
      return number_to_string(value.number);
    case Value::Type::String:
      return json_string_escape(value.string);
    case Value::Type::Array: {
      std::string out = "[";
      for (std::size_t i = 0; i < value.array.size(); ++i) {
        if (i != 0) {
          out += ",";
        }
        out += js_json_stringify(value.array[i]);
      }
      out += "]";
      return out;
    }
    case Value::Type::Object: {
      std::string out = "{";
      for (std::size_t i = 0; i < value.object.size(); ++i) {
        if (i != 0) {
          out += ",";
        }
        out += json_string_escape(value.object[i].first);
        out += ":";
        out += js_json_stringify(value.object[i].second);
      }
      out += "}";
      return out;
    }
  }
  return "";
}

bool python_truthy(const Value &value) {
  switch (value.type) {
    case Value::Type::Undefined:
      return true;
    case Value::Type::Null:
      return false;
    case Value::Type::Bool:
      return value.boolean;
    case Value::Type::Number:
      return value.number != 0.0;
    case Value::Type::String:
      return !value.string.empty();
    case Value::Type::Array:
      return !value.array.empty();
    case Value::Type::Object:
      return !value.object.empty();
  }
  return true;
}

const Value *object_get(const Value &object, const std::string &key) {
  if (object.type != Value::Type::Object) {
    return nullptr;
  }
  for (const auto &field : object.object) {
    if (field.first == key) {
      return &field.second;
    }
  }
  return nullptr;
}

struct DateOnly {
  int year;
  int month;
  int day;
};

bool leap_year(int y) {
  return (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
}

int days_in_month(int y, int m) {
  static const int days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  if (m == 2) {
    return leap_year(y) ? 29 : 28;
  }
  if (m < 1 || m > 12) {
    return 0;
  }
  return days[m - 1];
}

long long days_from_civil(int y, unsigned m, unsigned d) {
  y -= m <= 2;
  const int era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(y - era * 400);
  const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return static_cast<long long>(era) * 146097 + static_cast<long long>(doe) - 719468;
}

DateOnly parse_date_only(const Value &value) {
  std::string text = js_string(value);
  bool shape = text.size() == 10 && std::isdigit(static_cast<unsigned char>(text[0])) &&
               std::isdigit(static_cast<unsigned char>(text[1])) &&
               std::isdigit(static_cast<unsigned char>(text[2])) &&
               std::isdigit(static_cast<unsigned char>(text[3])) && text[4] == '-' &&
               std::isdigit(static_cast<unsigned char>(text[5])) &&
               std::isdigit(static_cast<unsigned char>(text[6])) && text[7] == '-' &&
               std::isdigit(static_cast<unsigned char>(text[8])) &&
               std::isdigit(static_cast<unsigned char>(text[9]));
  if (!shape) {
    throw std::runtime_error("parsing time " + js_json_stringify(value) + " as \"2006-01-02\": cannot parse date");
  }

  int year = std::stoi(text.substr(0, 4));
  int month = std::stoi(text.substr(5, 2));
  int day = std::stoi(text.substr(8, 2));
  if ((year >= 0 && year <= 99) || month < 1 || month > 12 || day < 1 || day > days_in_month(year, month)) {
    throw std::runtime_error("parsing time " + js_json_stringify(value) + ": day out of range");
  }
  return DateOnly{year, month, day};
}

DateOnly local_today() {
  std::time_t now = std::time(nullptr);
  std::tm local{};
#if defined(_WIN32)
  localtime_s(&local, &now);
#else
  localtime_r(&now, &local);
#endif
  return DateOnly{local.tm_year + 1900, local.tm_mon + 1, local.tm_mday};
}

bool date_less(const DateOnly &a, const DateOnly &b) {
  return days_from_civil(a.year, static_cast<unsigned>(a.month), static_cast<unsigned>(a.day)) <
         days_from_civil(b.year, static_cast<unsigned>(b.month), static_cast<unsigned>(b.day));
}

std::string canonical_key(const Value &value) {
  return js_json_stringify(value);
}

struct Summary {
  Value user_id;
  int completed = 0;
  int missed = 0;
};

struct PyKey {
  int group = 0;
  double number = 0.0;
  std::string text;
};

PyKey py_key(const Value &value) {
  switch (value.type) {
    case Value::Type::Null:
      return PyKey{0, 0.0, ""};
    case Value::Type::Bool:
      return PyKey{1, value.boolean ? 1.0 : 0.0, ""};
    case Value::Type::Number:
      return PyKey{1, value.number, ""};
    case Value::Type::String:
      return PyKey{2, 0.0, value.string};
    default:
      return PyKey{3, 0.0, js_string(value)};
  }
}

bool py_key_less(const Value &a, const Value &b) {
  PyKey ka = py_key(a);
  PyKey kb = py_key(b);
  if (ka.group != kb.group) {
    return ka.group < kb.group;
  }
  if (ka.group == 1 && ka.number != kb.number) {
    return ka.number < kb.number;
  }
  return ka.text < kb.text;
}

std::string ljust(const std::string &s, std::size_t width) {
  if (s.size() >= width) {
    return s;
  }
  return s + std::string(width - s.size(), ' ');
}

size_t curl_write(char *ptr, size_t size, size_t nmemb, void *userdata) {
  auto *body = static_cast<std::string *>(userdata);
  body->append(ptr, size * nmemb);
  return size * nmemb;
}

size_t curl_header(char *buffer, size_t size, size_t nitems, void *userdata) {
  auto *status = static_cast<std::string *>(userdata);
  std::string line(buffer, size * nitems);
  if (line.rfind("HTTP/", 0) == 0) {
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) {
      line.pop_back();
    }
    std::istringstream input(line);
    std::string http;
    long code = 0;
    input >> http >> code;
    std::string reason;
    std::getline(input, reason);
    if (!reason.empty() && reason[0] == ' ') {
      reason.erase(reason.begin());
    }
    *status = reason;
  }
  return size * nitems;
}

Value fetch_json(const std::string &url) {
  CURL *curl = curl_easy_init();
  if (curl == nullptr) {
    throw std::runtime_error("failed to initialize curl");
  }

  std::string body;
  std::string reason;
  curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, curl_header);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, &reason);

  CURLcode rc = curl_easy_perform(curl);
  if (rc != CURLE_OK) {
    std::string message = curl_easy_strerror(rc);
    curl_easy_cleanup(curl);
    throw std::runtime_error(message);
  }

  long code = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
  curl_easy_cleanup(curl);

  if (code < 200 || code >= 300) {
    std::ostringstream rendered;
    rendered << code;
    if (!reason.empty()) {
      rendered << " " << reason;
    }
    std::cerr << "bad status: " << rendered.str() << "\n";
    std::exit(1);
  }

  return JsonParser(body).parse();
}

void usage(const char *program) {
  std::cerr << "usage: " << program << " <todos-url>\n";
  std::exit(1);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    usage(argv[0]);
  }

  try {
    Value todos = fetch_json(argv[1]);
    DateOnly today = local_today();
    std::map<std::string, Summary> by_user;
    std::vector<std::string> insertion_order;

    if (todos.type == Value::Type::Array) {
      for (const Value &todo : todos.array) {
        const Value *user_field = object_get(todo, "userId");
        Value user_id = user_field == nullptr ? Value::undefined() : *user_field;
        std::string key = canonical_key(user_id);
        auto found = by_user.find(key);
        if (found == by_user.end()) {
          insertion_order.push_back(key);
          found = by_user.emplace(key, Summary{user_id, 0, 0}).first;
        }

        Summary &summary = found->second;
        const Value *completed_field = object_get(todo, "completed");
        Value completed = completed_field == nullptr ? Value::undefined() : *completed_field;
        if (python_truthy(completed)) {
          summary.completed += 1;
        } else {
          const Value *due_field = object_get(todo, "dueDate");
          Value due_value = due_field == nullptr ? Value::undefined() : *due_field;
          DateOnly due = parse_date_only(due_value);
          if (date_less(due, today)) {
            summary.missed += 1;
          }
        }
      }
    }

    std::vector<Summary> rows;
    for (const std::string &key : insertion_order) {
      rows.push_back(by_user[key]);
    }

    std::stable_sort(rows.begin(), rows.end(), [](const Summary &a, const Summary &b) {
      if (a.completed != b.completed) {
        return a.completed > b.completed;
      }
      if (a.missed != b.missed) {
        return a.missed > b.missed;
      }
      return py_key_less(a.user_id, b.user_id);
    });

    std::cout << "USER  COMPLETED  MISSED\n";
    for (const Summary &summary : rows) {
      std::cout << ljust(py_str(summary.user_id), 5) << " " << ljust(std::to_string(summary.completed), 10) << " "
                << summary.missed << "\n";
    }
  } catch (const std::exception &e) {
    std::cerr << e.what() << "\n";
    return 1;
  }

  return 0;
}
