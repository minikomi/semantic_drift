#include <curl/curl.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <ctime>
#include <exception>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using json = nlohmann::json;

struct HttpResponse {
  long status = 0;
  std::string reason;
  std::string body;
};

struct DateOnly {
  int year = 0;
  int month = 0;
  int day = 0;
};

struct Summary {
  json user_id;
  int completed = 0;
  int missed = 0;
};

static void fail_with(const std::string& message) {
  std::cerr << message << "\n";
  std::exit(1);
}

static std::string json_key(const json& value) {
  return value.dump();
}

static std::string display_value(const json& value) {
  if (value.is_string()) {
    return value.get<std::string>();
  }
  if (value.is_number_integer()) {
    return std::to_string(value.get<long long>());
  }
  if (value.is_number_unsigned()) {
    return std::to_string(value.get<unsigned long long>());
  }
  if (value.is_number_float()) {
    std::ostringstream out;
    out << value.get<double>();
    return out.str();
  }
  if (value.is_boolean()) {
    return value.get<bool>() ? "true" : "false";
  }
  if (value.is_null()) {
    return "";
  }
  return value.dump();
}

static bool same_sort_type(const json& a, const json& b) {
  if (a.is_number() && b.is_number()) {
    return true;
  }
  return a.type() == b.type();
}

static bool user_id_less(const json& a, const json& b) {
  if (a.is_number() && b.is_number()) {
    return a.get<double>() < b.get<double>();
  }
  if (a.is_string() && b.is_string()) {
    return a.get<std::string>() < b.get<std::string>();
  }
  if (a.is_boolean() && b.is_boolean()) {
    return static_cast<int>(a.get<bool>()) < static_cast<int>(b.get<bool>());
  }
  return a.dump() < b.dump();
}

static size_t write_body(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* body = static_cast<std::string*>(userdata);
  body->append(ptr, size * nmemb);
  return size * nmemb;
}

static std::string trim_right_crlf(std::string line) {
  while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) {
    line.pop_back();
  }
  return line;
}

static size_t write_header(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* reason = static_cast<std::string*>(userdata);
  std::string line = trim_right_crlf(std::string(ptr, size * nmemb));
  if (line.rfind("HTTP/", 0) == 0) {
    std::size_t first_space = line.find(' ');
    if (first_space != std::string::npos) {
      std::size_t second_space = line.find(' ', first_space + 1);
      if (second_space != std::string::npos && second_space + 1 < line.size()) {
        *reason = line.substr(second_space + 1);
      } else {
        reason->clear();
      }
    }
  }
  return size * nmemb;
}

static HttpResponse http_get(const std::string& url) {
  CURL* curl = curl_easy_init();
  if (!curl) {
    throw std::runtime_error("failed to initialize curl");
  }

  HttpResponse response;
  char error_buffer[CURL_ERROR_SIZE] = {0};

  curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_body);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response.body);
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, write_header);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, &response.reason);
  curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, error_buffer);

  CURLcode code = curl_easy_perform(curl);
  if (code != CURLE_OK) {
    std::string message = error_buffer[0] ? error_buffer : curl_easy_strerror(code);
    curl_easy_cleanup(curl);
    throw std::runtime_error(message);
  }

  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response.status);
  curl_easy_cleanup(curl);
  return response;
}

static bool is_leap_year(int year) {
  return (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
}

static int days_in_month(int year, int month) {
  static const int days[] = {0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  if (month == 2 && is_leap_year(year)) {
    return 29;
  }
  if (month < 1 || month > 12) {
    return 0;
  }
  return days[month];
}

static std::string parse_error_message(const std::string& value) {
  return "parsing time \"" + value + "\" as \"2006-01-02\": cannot parse \"" + value + "\" as \"2006\"";
}

static DateOnly parse_date_only_in_local_time(const std::string& value) {
  bool shape_ok = value.size() == 10 && value[4] == '-' && value[7] == '-';
  for (std::size_t i = 0; i < value.size() && shape_ok; ++i) {
    if (i == 4 || i == 7) {
      continue;
    }
    shape_ok = std::isdigit(static_cast<unsigned char>(value[i])) != 0;
  }

  if (!shape_ok) {
    fail_with(parse_error_message(value));
  }

  DateOnly date;
  date.year = std::stoi(value.substr(0, 4));
  date.month = std::stoi(value.substr(5, 2));
  date.day = std::stoi(value.substr(8, 2));

  if (date.month < 1 || date.month > 12 || date.day < 1 || date.day > days_in_month(date.year, date.month)) {
    fail_with(parse_error_message(value));
  }
  return date;
}

static DateOnly today_local() {
  std::time_t now = std::time(nullptr);
  std::tm local_tm{};
#if defined(_WIN32)
  localtime_s(&local_tm, &now);
#else
  localtime_r(&now, &local_tm);
#endif
  return DateOnly{local_tm.tm_year + 1900, local_tm.tm_mon + 1, local_tm.tm_mday};
}

static bool date_less(const DateOnly& a, const DateOnly& b) {
  if (a.year != b.year) return a.year < b.year;
  if (a.month != b.month) return a.month < b.month;
  return a.day < b.day;
}

static void print_row(const std::string& user_id, const std::string& completed, int missed) {
  std::cout << user_id;
  if (user_id.size() < 5) {
    std::cout << std::string(5 - user_id.size(), ' ');
  }
  std::cout << ' ';
  std::cout << completed;
  if (completed.size() < 10) {
    std::cout << std::string(10 - completed.size(), ' ');
  }
  std::cout << ' ';
  std::cout << missed << "\n";
}

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: " << argv[0] << " <todos-url>\n";
    return 1;
  }

  try {
    curl_global_init(CURL_GLOBAL_DEFAULT);

    HttpResponse response = http_get(argv[1]);
    if (response.status < 200 || response.status >= 300) {
      std::string message = "bad status: " + std::to_string(response.status);
      if (!response.reason.empty()) {
        message += " " + response.reason;
      }
      fail_with(message);
    }

    json todos = json::parse(response.body);
    DateOnly today = today_local();
    std::map<std::string, Summary> by_user;

    for (const auto& todo : todos) {
      json user_id = todo.at("userId");
      std::string key = json_key(user_id);
      auto it = by_user.find(key);
      if (it == by_user.end()) {
        Summary summary;
        summary.user_id = user_id;
        it = by_user.emplace(key, std::move(summary)).first;
      }

      if (todo.at("completed").get<bool>()) {
        it->second.completed += 1;
      } else {
        DateOnly due = parse_date_only_in_local_time(todo.at("dueDate").get<std::string>());
        if (date_less(due, today)) {
          it->second.missed += 1;
        }
      }
    }

    std::vector<Summary> rows;
    for (const auto& entry : by_user) {
      rows.push_back(entry.second);
    }

    std::sort(rows.begin(), rows.end(), [](const Summary& a, const Summary& b) {
      if (a.completed != b.completed) return a.completed > b.completed;
      if (a.missed != b.missed) return a.missed > b.missed;
      return user_id_less(a.user_id, b.user_id);
    });

    std::cout << "USER  COMPLETED  MISSED\n";
    for (const auto& row : rows) {
      print_row(display_value(row.user_id), std::to_string(row.completed), row.missed);
    }

    curl_global_cleanup();
    return 0;
  } catch (const std::exception& error) {
    fail_with(error.what());
  }
}
