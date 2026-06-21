#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "json"
require "net/http"
require "uri"

DATE_ONLY_RE = /\A(\d{4})-(\d{2})-(\d{2})\z/
UNDEFINED = Object.new

def usage
  warn "usage: #{$PROGRAM_NAME} <todos-url>"
  exit 1
end

def exit_with_error(err)
  warn err.to_s
  exit 1
end

def js_json_stringify(value)
  return "undefined" if value.equal?(UNDEFINED)

  JSON.generate(value)
end

def js_string(value)
  return "undefined" if value.equal?(UNDEFINED)
  return "null" if value.nil?
  return "true" if value == true
  return "false" if value == false

  py_str(value)
end

def py_str(value)
  return "None" if value.nil?
  return "True" if value == true
  return "False" if value == false
  return py_list_str(value) if value.is_a?(Array)
  return py_hash_str(value) if value.is_a?(Hash)

  value.to_s
end

def py_list_str(values)
  "[#{values.map { |item| py_repr(item) }.join(', ')}]"
end

def py_hash_str(values)
  "{#{values.map { |key, value| "#{py_repr(key)}: #{py_repr(value)}" }.join(', ')}}"
end

def py_repr(value)
  return "None" if value.nil?
  return "True" if value == true
  return "False" if value == false
  return py_list_str(value) if value.is_a?(Array)
  return py_hash_str(value) if value.is_a?(Hash)
  return value.inspect if value.is_a?(String)

  value.to_s
end

def python_truthy?(value)
  case value
  when nil, false
    false
  when String, Array, Hash
    !value.empty?
  when Numeric
    value != 0
  else
    true
  end
end

def parse_go_date_only_in_local_time(value)
  text = js_string(value)
  match = DATE_ONLY_RE.match(text)
  unless match
    raise ArgumentError,
          "parsing time #{js_json_stringify(value)} as #{js_json_stringify('2006-01-02')}: cannot parse date"
  end

  year = match[1].to_i
  month = match[2].to_i
  day = match[3].to_i

  raise ArgumentError, "parsing time #{js_json_stringify(value)}: day out of range" if year >= 0 && year <= 99

  begin
    Date.new(year, month, day)
  rescue StandardError
    raise ArgumentError, "parsing time #{js_json_stringify(value)}: day out of range"
  end
end

def fetch_json(url)
  uri = URI(url)
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 10) do |http|
    http.get(uri.request_uri.empty? ? "/" : uri.request_uri)
  end

  unless response.code.to_i >= 200 && response.code.to_i < 300
    rendered = response.message && !response.message.empty? ? "#{response.code} #{response.message}" : response.code
    warn "bad status: #{rendered}"
    exit 1
  end

  JSON.parse(response.body)
end

def py_key(value)
  case value
  when nil
    [0, ""]
  when false
    [1, 0]
  when true
    [1, 1]
  when Numeric
    [1, value]
  when String
    [2, value]
  else
    [3, value.to_s]
  end
end

def main
  usage unless ARGV.length == 1

  begin
    todos = fetch_json(ARGV[0])
  rescue SystemExit
    raise
  rescue StandardError => e
    exit_with_error(e)
  end

  today = Date.today
  by_user = {}

  todos.each do |todo|
    user_id = todo.key?("userId") ? todo["userId"] : UNDEFINED
    by_user[user_id] ||= { "userId" => user_id, "completed" => 0, "missed" => 0 }

    summary = by_user[user_id]
    if python_truthy?(todo.key?("completed") ? todo["completed"] : UNDEFINED)
      summary["completed"] += 1
    else
      begin
        due = parse_go_date_only_in_local_time(todo.key?("dueDate") ? todo["dueDate"] : UNDEFINED)
      rescue StandardError => e
        exit_with_error(e)
      end
      summary["missed"] += 1 if due < today
    end
  end

  rows = by_user.values
  rows.sort_by! { |item| [-item["completed"], -item["missed"], py_key(item["userId"])] }

  $stdout.write("USER  COMPLETED  MISSED\n")
  rows.each do |summary|
    user = py_str(summary["userId"]).ljust(5)
    completed = summary["completed"].to_s.ljust(10)
    $stdout.write("#{user} #{completed} #{summary['missed']}\n")
  end
end

main if $PROGRAM_NAME == __FILE__
