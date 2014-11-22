require_relative 'helper'
require 'fluent/test'
require 'fluent/plugin/out_file2'
require 'fileutils'
require 'time'
require 'delorean'

module Fluent
  module Test
    class File2OutputTestDriver < InputTestDriver
      def initialize(klass, tag='test', &block)
        super(klass, &block)
        @tag = tag
        @entries = []
      end

      attr_accessor :tag

      def emit(record, time=Time.now)
        @entries << [time, record]
      end

      def expect_format(str)
        (@expected_buffer ||= '') << str
      end

      def run(&block)
        super {
          buffer = ''
          @entries.each {|time, record|
            es = OneEventStream.new(time.to_i, record)
            chain = TestOutputChain.new
            @instance.emit(@tag, es, chain)
            buffer << @instance.format(@tag, time, record)
          }

          block.call if block

          if @expected_buffer
            assert_equal(@expected_buffer, buffer)
          end
        }

        @instance.strftime_path # for test
      end
    end
  end
end

class File2OutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    FileUtils.rm_rf(TMP_DIR)
    FileUtils.mkdir_p(TMP_DIR)
    Delorean.time_travel_to  Time.parse("2011-01-02 13:14:15 UTC")
  end

  def treadown
    Delorean.back_to_the_present
  end

  TMP_DIR = File.expand_path(File.dirname(__FILE__) + "/../tmp/out_file#{ENV['TEST_ENV_NUMBER']}")
  SYMLINK_PATH = File.expand_path("#{TMP_DIR}/current")

  CONFIG = %[
    path #{TMP_DIR}/out_file_test
    # compress gz
    utc
  ]

  def create_driver(conf = CONFIG)
    Fluent::Test::File2OutputTestDriver.new(Fluent::File2Output).configure(conf)
  end

  def with_timezone(timezone = 'UTC', &block)
    old = ENV['TZ']
    ENV['TZ'] = timezone
    output = yield
    ENV['TZ'] = old
    output
  end

  def test_configure
    d = create_driver %[
      path test_path
      # compress gz
    ]
    assert_equal 'test_path', d.instance.path
    # assert_equal :gz, d.instance.compress
  end

  def test_default_localtime
    d = create_driver(%[path #{TMP_DIR}/out_file_test])
    time = Time.parse("2011-01-02 13:14:15 UTC").to_i

    with_timezone('Asia/Taipei') do
      d.emit({"a"=>1}, time)
      d.expect_format %[2011-01-02T21:14:15+08:00\ttest\t{"a":1}\n]
      d.run
    end
  end

  def test_format
    d = create_driver

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    d.expect_format %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n]
    d.expect_format %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n]

    d.run
  end

  def test_timezone_1
    d = create_driver %[
      path #{TMP_DIR}/out_file_test
      timezone Asia/Taipei
    ]

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i

    d.emit({"a"=>1}, time)
    d.expect_format %[2011-01-02T21:14:15+08:00\ttest\t{"a":1}\n]
    d.run
  end

  def test_timezone_2
    d = create_driver %[
      path #{TMP_DIR}/out_file_test
      timezone -03:30
    ]

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i

    d.emit({"a"=>1}, time)
    d.expect_format %[2011-01-02T09:44:15-03:30\ttest\t{"a":1}\n]
    d.run
  end

  def test_timezone_invalid
    assert_raise(Fluent::ConfigError) do
      create_driver %[
        path #{TMP_DIR}/out_file_test
        timezone Invalid/Invalid
      ]
    end
  end

  # def check_gzipped_result(path, expect)
  #   # Zlib::GzipReader has a bug of concatenated file: https://bugs.ruby-lang.org/issues/9790
  #   # Following code from https://www.ruby-forum.com/topic/971591#979520
  #   result = ''
  #   File.open(path) { |io|
  #     loop do
  #       gzr = Zlib::GzipReader.new(io)
  #       result << gzr.read
  #       unused = gzr.unused
  #       gzr.finish
  #       break if unused.nil?
  #       io.pos -= unused.length
  #     end
  #   }

  #   assert_equal expect, result
  # end

  def check_result(path, expect)
    assert_equal expect, File.read(path)
  end

  def test_write
    d = create_driver

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # FileOutput#write returns path
    path = d.run
    expect_path = "#{TMP_DIR}/out_file_test.20110102.log"
    assert_equal expect_path, path

    check_result(path, %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] + %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n])
  end

  def test_write_with_format_json
    d = create_driver [CONFIG, 'format json', 'include_time_key true', 'time_as_epoch'].join("\n")

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # FileOutput#write returns path
    path = d.run
    check_result(path, %[#{Yajl.dump({"a" => 1, 'time' => time})}\n] + %[#{Yajl.dump({"a" => 2, 'time' => time})}\n])
  end

  def test_write_with_format_ltsv
    d = create_driver [CONFIG, 'format ltsv', 'include_time_key true'].join("\n")

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # FileOutput#write returns path
    path = d.run
    check_result(path, %[a:1\ttime:2011-01-02T13:14:15Z\n] + %[a:2\ttime:2011-01-02T13:14:15Z\n])
  end

  def test_write_with_format_single_value
    d = create_driver [CONFIG, 'format single_value', 'message_key a'].join("\n")

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({"a"=>1}, time)
    d.emit({"a"=>2}, time)

    # FileOutput#write returns path
    path = d.run
    check_result(path, %[1\n] + %[2\n])
  end

  def test_write_with_symlink
    conf = CONFIG + %[
      symlink_path #{SYMLINK_PATH}
    ]
    symlink_path = "#{SYMLINK_PATH}"

    begin
      d = create_driver(conf)
      time = Time.parse("2011-01-02 13:14:15 UTC").to_i
      d.emit({"a"=>1}, time)
      path = d.run

      assert File.exists?(symlink_path)
      assert File.symlink?(symlink_path)
    ensure
      FileUtils.rm_rf(symlink_path)
    end
  end

  sub_test_case 'path' do
    test 'normal' do
      d = create_driver(%[
        path #{TMP_DIR}/out_file_test
        time_slice_format %Y-%m-%d-%H
        utc true
      ])
      time = Time.parse("2011-01-02 13:14:15 UTC").to_i
      d.emit({"a"=>1}, time)
      # FileOutput#write returns path
      path = d.run
      assert_equal "#{TMP_DIR}/out_file_test.2011-01-02-13.log", path
    end

    test '*' do
      d = create_driver(%[
        path #{TMP_DIR}/out_file_test.*.txt
        time_slice_format %Y-%m-%d-%H
        utc true
      ])
      time = Time.parse("2011-01-02 13:14:15 UTC").to_i
      d.emit({"a"=>1}, time)
      path = d.run
      assert_equal "#{TMP_DIR}/out_file_test.2011-01-02-13.txt", path
    end

    test 'strftime' do
      d = create_driver(%[
        path #{TMP_DIR}/out_file_test.%Y-%m-%d-%H.log
        utc true
      ])
      time = Time.parse("2011-01-02 13:14:15 UTC").to_i
      d.emit({"a"=>1}, time)
      path = d.run
      assert_equal "#{TMP_DIR}/out_file_test.2011-01-02-13.log", path
    end
  end
end
