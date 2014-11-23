module Fluent
  class File2Output < Output
    Plugin.register_output('file2', self)

    unless method_defined?(:log)
      define_method(:log) { $log }
    end

    config_param :path, :string
    config_param :time_slice_format, :string, :default => '%Y%m%d' # for out_file compatibility
    config_param :format, :string, :default => 'out_file' # params of HandleTagAndTimeMixin and TextFormatters are also available
    config_param :symlink_path, :string, :default => nil

    SUPPORTED_COMPRESS = {
      'gz' => :gz,
      'gzip' => :gz,
    }
    config_param :compress, :default => nil do |val|
      c = SUPPORTED_COMPRESS[val]
      unless c
        raise ConfigError, "Unsupported compression algorithm '#{val}'"
      end
      c
    end
    config_param :time_slice_wait, :time, :default => nil # for out_file compatibility
    config_param :compress_wait, :time, :default => 10*60
    
    attr_reader :time_slicer, :compress_thread, :compress_interval

    # for test
    def strftime_path
      @writer.strftime_path
    end

    def initialize
      require 'zlib'
      require 'fileutils'
      require 'time'
      require 'thread'
      super
    end

    def configure(conf)
      super

      conf['format'] = @format
      @formatter = TextFormatter.create(conf)

      # configure_path(conf)
      if pos = @path.index('*')
        path_prefix = @path[0,pos]
        path_suffix = @path[pos+1..-1]
        @time_slice_path = "#{path_prefix}#{@time_slice_format}#{path_suffix}"
      elsif @path =~ /%Y|%m|%d|%H|%M|%S/
        @time_slice_path = @path
      else
        path_prefix = @path+"."
        path_suffix = ".log"
        @time_slice_path = "#{path_prefix}#{@time_slice_format}#{path_suffix}"
      end
      begin
        Time.now.strftime(@time_slice_path)
      rescue => e
        raise ConfigError, "#{e.class}: #{e.message}"
      end

      # configure_writer(conf)
      if conf['utc']
        @localtime = false
      elsif conf['localtime']
        @localtime = true
      end
      if conf['timezone']
        @timezone = conf['timezone']
        Fluent::Timezone.validate!(@timezone)
      end
      @time_slicer =
        if @timezone
          Timezone.formatter(@timezone, @time_slice_path)
        elsif @localtime
          Proc.new {|time|
            Time.at(time).strftime(@time_slice_path)
          }
        else
          Proc.new {|time|
            Time.at(time).utc.strftime(@time_slice_path)
          }
        end
      @writer = FileWriter.new(self)

      # configure_compress(conf)
      if @compress
        @compress_wait = @time_slice_wait if @time_slice_wait # for compatibility with out_file
        @compress_interval =
          if @time_slice_path.index('%S')
            1
          elsif @time_slice_path.index('%M')
            60
          elsif @time_slice_path.index('%H')
            60 * 60
          elsif @time_slice_path.index('%d')
            24 * 60 * 60
          else
            raise ConfigError, 'path (or time_slice_format) must include %d or %H or %M or %S'
          end
        @compress_thread = CompressThread.new(self)
      end

    end

    def start
      super
      @compress_thread.start if @compress_thread
    end

    def shutdown
      @compress_thread.shutdown if @compress_thread
    end

    def format(tag, time, record)
      @formatter.format(tag, time, record)
    end

    def emit(tag, es, chain)
      es.each do |time, record|
        msg = format(tag, time, record)
        @writer.write(msg)
      end

      chain.next
    end

    class CompressThread
      attr_reader :log

      def initialize(output)
        @log = output.log
        @output = output
        @compress = output.compress
        @compress_wait = output.compress_wait
        @compress_interval = output.compress_interval
        @time_slicer = output.time_slicer
        @sleep = [[@compress_wait, 1].min, 0.1].max
      end

      def start
        @running = true
        @thread = Thread.new(&method(:run))
      end

      def shutdown
        @running = false
        @thread.join
      end

      def run
        now = Time.now.to_i
        wait_until = Time.at(now - (now % @compress_interval) + @compress_interval + @compress_wait)
        while @running
          # sleep @interval is bad because it blocks on shutdown
          while @running && Time.now <= wait_until
            sleep @sleep
          end
          strftime_path = @time_slicer.call((Time.now - @compress_wait).to_i)
          compress(strftime_path)
          wait_until += @compress_interval
        end
      end

      def compress(path)
        case @compress
        when :gz
          begin
            file = File.open(path, 'r')
            create_file("#{path}.gz") do |gz_file|
              gz = Zlib::GzipWriter.new(gz_file)
              FileUtils.copy_stream(file, gz)
              gz.close
              file.close rescue nil
              File.unlink(path) rescue nil
              log.info "gzip #{path} to #{path}.gz. #{path} is removed."
            end
          rescue Errno::ENOENT
            log.info "#{path} is not found. compress skipped."
          else
            file.close rescue nil
          end
        end
      end

      def create_file(filename, &block)
        begin
          File.open filename, (File::WRONLY | File::APPEND | File::CREAT | File::EXCL), DEFAULT_FILE_PERMISSION, &block
        rescue Errno::EEXIST
          log.debug "#{filename} already exists."
          # do nothing
        end
      end
    end

    class FileWriter
      attr_reader :log
      attr_reader :strftime_path # for test

      def initialize(output)
        @log = output.log
        @output = output
        @time_slicer = output.time_slicer
        @symlink_path = output.symlink_path
        @mutex = Mutex.new
        @strftime_path = nil
        @file = nil
      end

      def write(msg)
        begin
          @mutex.synchronize do
            if @file.nil? || !same_path?
              begin
                @strftime_path = @time_slicer.call(Time.now.to_i)
                @file.close rescue nil if @file
                FileUtils.mkdir_p File.dirname(@strftime_path), :mode => 0755
                @file = create_file(@strftime_path)
                FileUtils.ln_sf(@strftime_path, @symlink_path) if @symlink_path
              rescue
                log.warn("file shifting failed. #{$!}")
              end
            end

            begin
              @file.write msg
            rescue
              log.warn("file writing failed. #{$!}")
            end
          end
        rescue Exception => ignored
          log.warn("file writing failed. #{ignored}")
        end
      end

      def close
        if !@file.nil? && !@file.closed?
          @file.close
        end
      end

      private

      # return nil if file not found
      def open_file(filename)
        begin
          f = File.open filename, (File::WRONLY | File::APPEND)
          f.sync = true
        rescue Errno::ENOENT
          return nil
        end
        f
      end

      def create_file(filename)
        begin
          f = File.open filename, (File::WRONLY | File::APPEND | File::CREAT | File::EXCL), DEFAULT_FILE_PERMISSION
          f.sync = true
          log.info "#{filename} is created."
        rescue Errno::EEXIST
          f = open_file(filename)
          log.debug "#{filename} already exists."
        end
        f
      end

      def same_path?
        @strftime_path == @time_slicer.call(Time.now.to_i)
      end
    end
  end
end
