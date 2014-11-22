module Fluent
  class File2Output < Output
    Plugin.register_output('file2', self)

    unless method_defined?(:log)
      define_method(:log) { $log }
    end

    config_param :path, :string
    config_param :time_slice_format, :string, :default => '%Y%m%d'
    config_param :format, :string, :default => 'out_file'
    # params of HandleTagAndTimeMixin and TextFormatters are also available
    config_param :symlink_path, :string, :default => nil

    # SUPPORTED_COMPRESS = {
    #   'gz' => :gz,
    #   'gzip' => :gz,
    # }
    # config_param :compress, :default => nil do |val|
    #   c = SUPPORTED_COMPRESS[val]
    #   unless c
    #     raise ConfigError, "Unsupported compression algorithm '#{val}'"
    #   end
    #   c
    # end

    def initialize
      # require 'zlib'
      require 'fileutils'
      require 'time'
      super
    end

    def configure(conf)
      super

      conf['format'] = @format
      @formatter = TextFormatter.create(conf)

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

      @writer = StrftimeFileWriter.new(@log, @time_slicer, @symlink_path)
    end

    def format(tag, time, record)
      @formatter.format(tag, time, record)
    end

    # for test
    def strftime_path
      @writer.strftime_path
    end

    def emit(tag, es, chain)
      es.each do |time, record|
        msg = format(tag, time, record)
        @writer.write(msg)
      end

      # case @compress
      # when nil
      #   File.open(path, "a", DEFAULT_FILE_PERMISSION) {|f|
      #     chunk.write_to(f)
      #   }
      # when :gz
      #   File.open(path, "a", DEFAULT_FILE_PERMISSION) {|f|
      #     gz = Zlib::GzipWriter.new(f)
      #     chunk.write_to(gz)
      #     gz.close
      #   }
      # end

      chain.next
    end

    class StrftimeFileWriter
      attr_reader :log
      attr_reader :strftime_path # for test

      def initialize(log, time_slicer, symlink_path)
        @log = log
        @time_slicer = time_slicer
        @symlink_path = symlink_path
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
          f = File.open filename, (File::WRONLY | File::APPEND | File::CREAT | File::EXCL)
          f.sync = true
        rescue Errno::EEXIST
          f = open_file(filename)
        end
        f
      end

      def same_path?
        @strftime_path == @time_slicer.call(Time.now.to_i)
      end
    end
  end
end

