module Excon
  class Connection
    VALID_CONNECTION_KEYS = [:body, :family, :headers, :host, :path, :port, :query, :scheme, :user, :password,
                             :instrumentor, :instrumentor_name, :ssl_ca_file, :ssl_verify_peer, :chunk_size,
                             :nonblock, :retry_limit, :connect_timeout, :read_timeout, :write_timeout, :captures,
                             :exception, :expects, :mock, :proxy, :method, :idempotent, :request_block, :response_block,
                             :middlewares, :retries_remaining, :connection, :stack, :response, :pipeline]
    attr_reader :data

    def params
      $stderr.puts("Excon::Connection#params is deprecated use Excon::Connection#data instead (#{caller.first})")
      @data
    end
    def params=(new_params)
      $stderr.puts("Excon::Connection#params= is deprecated use Excon::Connection#data= instead (#{caller.first})")
      @data = new_params
    end

    def proxy
      $stderr.puts("Excon::Connection#proxy is deprecated use Excon::Connection#data[:proxy] instead (#{caller.first})")
      @data[:proxy]
    end
    def proxy=(new_proxy)
      $stderr.puts("Excon::Connection#proxy= is deprecated use Excon::Connection#data[:proxy]= instead (#{caller.first})")
      @data[:proxy] = new_proxy
    end

    def assert_valid_keys_for_argument!(argument, valid_keys)
      invalid_keys = argument.keys - valid_keys
      return true if invalid_keys.empty?
      raise ArgumentError, "The following keys are invalid: #{invalid_keys.map(&:inspect).join(', ')}"
    end
    private :assert_valid_keys_for_argument!

    # Initializes a new Connection instance
    #   @param [String] url The destination URL
    #   @param [Hash<Symbol, >] params One or more optional params
    #     @option params [String] :body Default text to be sent over a socket. Only used if :body absent in Connection#request params
    #     @option params [Hash<Symbol, String>] :headers The default headers to supply in a request. Only used if params[:headers] is not supplied to Connection#request
    #     @option params [String] :host The destination host's reachable DNS name or IP, in the form of a String
    #     @option params [String] :path Default path; appears after 'scheme://host:port/'. Only used if params[:path] is not supplied to Connection#request
    #     @option params [Fixnum] :port The port on which to connect, to the destination host
    #     @option params [Hash]   :query Default query; appended to the 'scheme://host:port/path/' in the form of '?key=value'. Will only be used if params[:query] is not supplied to Connection#request
    #     @option params [String] :scheme The protocol; 'https' causes OpenSSL to be used
    #     @option params [String] :proxy Proxy server; e.g. 'http://myproxy.com:8888'
    #     @option params [Fixnum] :retry_limit Set how many times we'll retry a failed request.  (Default 4)
    #     @option params [Class] :instrumentor Responds to #instrument as in ActiveSupport::Notifications
    #     @option params [String] :instrumentor_name Name prefix for #instrument events.  Defaults to 'excon'
    def initialize(url, params = {})
      assert_valid_keys_for_argument!(params, VALID_CONNECTION_KEYS)
      uri = URI.parse(url)
      @data = Excon.defaults.merge({
        :host       => uri.host,
        :path       => uri.path,
        :port       => uri.port.to_s,
        :query      => uri.query,
        :scheme     => uri.scheme,
        :user       => (URI.decode(uri.user) if uri.user),
        :password   => (URI.decode(uri.password) if uri.password),
      }).merge!(params)
      # merge does not deep-dup, so make sure headers is not the original
      @data[:headers] = @data[:headers].dup

      if @data[:scheme] == HTTPS && (ENV.has_key?('https_proxy') || ENV.has_key?('HTTPS_PROXY'))
        @data[:proxy] = setup_proxy(ENV['https_proxy'] || ENV['HTTPS_PROXY'])
      elsif (ENV.has_key?('http_proxy') || ENV.has_key?('HTTP_PROXY'))
        @data[:proxy] = setup_proxy(ENV['http_proxy'] || ENV['HTTP_PROXY'])
      elsif @data.has_key?(:proxy)
        @data[:proxy] = setup_proxy(@data[:proxy])
      end

      if @data[:proxy]
        @data[:headers]['Proxy-Connection'] ||= 'Keep-Alive'
        # https credentials happen in handshake
        if @data[:scheme] == 'http' && (@data[:proxy][:user] || @data[:proxy][:password])
          auth = ['' << @data[:proxy][:user].to_s << ':' << @data[:proxy][:password].to_s].pack('m').delete(Excon::CR_NL)
          @data[:headers]['Proxy-Authorization'] = 'Basic ' << auth
        end
      end

      if ENV.has_key?('EXCON_DEBUG') || ENV.has_key?('EXCON_STANDARD_INSTRUMENTOR')
        @data[:instrumentor] = Excon::StandardInstrumentor
      end

      # Use Basic Auth if url contains a login
      if uri.user || uri.password
        @data[:headers]['Authorization'] ||= 'Basic ' << ['' << uri.user.to_s << ':' << uri.password.to_s].pack('m').delete(Excon::CR_NL)
      end

      @socket_key = '' << @data[:host] << ':' << @data[:port]
      reset
    end

    def request_call(datum)
      begin
        if datum.has_key?(:response)
          # we already have data from a middleware, so bail
          return datum
        else
          socket.data = datum
          # start with "METHOD /path"
          request = datum[:method].to_s.upcase << ' '
          if @data[:proxy]
            request << datum[:scheme] << '://' << @data[:host] << ':' << @data[:port].to_s
          end
          request << datum[:path]

          # add query to path, if there is one
          case datum[:query]
          when String
            request << '?' << datum[:query]
          when Hash
            request << '?'
            datum[:query].each do |key, values|
              if values.nil?
                request << key.to_s << '&'
              else
                [values].flatten.each do |value|
                  request << key.to_s << '=' << CGI.escape(value.to_s) << '&'
                end
              end
            end
            request.chop! # remove trailing '&'
          end

          # finish first line with "HTTP/1.1\r\n"
          request << HTTP_1_1

          if datum.has_key?(:request_block)
            datum[:headers]['Transfer-Encoding'] = 'chunked'
          elsif ! (datum[:method].to_s.casecmp('GET') == 0 && datum[:body].nil?)
            # The HTTP spec isn't clear on it, but specifically, GET requests don't usually send bodies;
            # if they don't, sending Content-Length:0 can cause issues.
            datum[:headers]['Content-Length'] = detect_content_length(datum[:body])
          end

          # add headers to request
          datum[:headers].each do |key, values|
            [values].flatten.each do |value|
              request << key.to_s << ': ' << value.to_s << CR_NL
            end
          end

          # add additional "\r\n" to indicate end of headers
          request << CR_NL

          # write out the request, sans body
          socket.write(request)

          # write out the body
          if datum.has_key?(:request_block)
            while true
              chunk = datum[:request_block].call
              if FORCE_ENC
                chunk.force_encoding('BINARY')
              end
              if chunk.length > 0
                socket.write(chunk.length.to_s(16) << CR_NL << chunk << CR_NL)
              else
                socket.write('0' << CR_NL << CR_NL)
                break
              end
            end
          elsif !datum[:body].nil?
            if datum[:body].is_a?(String)
              unless datum[:body].empty?
                socket.write(datum[:body])
              end
            else
              if datum[:body].respond_to?(:binmode)
                datum[:body].binmode
              end
              if datum[:body].respond_to?(:pos=)
                datum[:body].pos = 0
              end
              while chunk = datum[:body].read(datum[:chunk_size])
                socket.write(chunk)
              end
            end
          end
        end
      rescue => error
        case error
        when Excon::Errors::StubNotFound, Excon::Errors::Timeout
          raise(error)
        else
          raise(Excon::Errors::SocketError.new(error))
        end
      end

      datum
    end

    def response_call(datum)
      datum
    end

    # Sends the supplied request to the destination host.
    #   @yield [chunk] @see Response#self.parse
    #   @param [Hash<Symbol, >] params One or more optional params, override defaults set in Connection.new
    #     @option params [String] :body text to be sent over a socket
    #     @option params [Hash<Symbol, String>] :headers The default headers to supply in a request
    #     @option params [String] :host The destination host's reachable DNS name or IP, in the form of a String
    #     @option params [String] :path appears after 'scheme://host:port/'
    #     @option params [Fixnum] :port The port on which to connect, to the destination host
    #     @option params [Hash]   :query appended to the 'scheme://host:port/path/' in the form of '?key=value'
    #     @option params [String] :scheme The protocol; 'https' causes OpenSSL to be used
    def request(params, &block)
      # @data has defaults, merge in new params to override
      datum = @data.merge(params)
      assert_valid_keys_for_argument!(params, VALID_CONNECTION_KEYS)
      datum[:headers] = @data[:headers].merge(datum[:headers] || {})
      datum[:headers]['Host']   ||= '' << datum[:host] << ':' << datum[:port]
      datum[:retries_remaining] ||= datum[:retry_limit]

      # if path is empty or doesn't start with '/', insert one
      unless datum[:path][0, 1] == '/'
        datum[:path].insert(0, '/')
      end

      if block_given?
        $stderr.puts("Excon requests with a block are deprecated, pass :response_block instead (#{caller.first})")
        datum[:response_block] = Proc.new
      end

      datum[:connection] = self

      datum[:stack] = datum[:middlewares].map do |middleware|
        lambda {|stack| middleware.new(stack)}
      end.reverse.inject(self) do |middlewares, middleware|
        middleware.call(middlewares)
      end
      datum = datum[:stack].request_call(datum)

      unless datum[:pipeline]
        datum = response(datum)

        if datum[:response][:headers]['Connection'] == 'close'
          reset
        end

        Excon::Response.new(datum[:response])
      else
        datum
      end
    rescue => request_error
      reset
      if datum[:idempotent] && [Excon::Errors::Timeout, Excon::Errors::SocketError,
          Excon::Errors::HTTPStatusError].any? {|ex| request_error.kind_of? ex } && datum[:retries_remaining] > 1
        datum[:retries_remaining] -= 1
        request(datum, &block)
      else
        if datum.has_key?(:instrumentor)
          datum[:instrumentor].instrument("#{datum[:instrumentor_name]}.error", :error => request_error)
        end
        raise(request_error)
      end
    end

    # Sends the supplied requests to the destination host using pipelining.
    #   @pipeline_params [Array<Hash>] pipeline_params An array of one or more optional params, override defaults set in Connection.new, see #request for details
    def requests(pipeline_params)
      pipeline_params.map do |params|
        request(params.merge!(:pipeline => true))
      end.map do |datum|
        Excon::Response.new(response(datum)[:response])
      end
    end

    def reset
      (old_socket = sockets.delete(@socket_key)) && old_socket.close
    end

    # Generate HTTP request verb methods
    Excon::HTTP_VERBS.each do |method|
      class_eval <<-DEF, __FILE__, __LINE__ + 1
        def #{method}(params={}, &block)
          request(params.merge!(:method => :#{method}), &block)
        end
      DEF
    end

    def retry_limit=(new_retry_limit)
      $stderr.puts("Excon::Connection#retry_limit= is deprecated, pass :retry_limit to the initializer (#{caller.first})")
      @data[:retry_limit] = new_retry_limit
    end

    def retry_limit
      $stderr.puts("Excon::Connection#retry_limit is deprecated, pass :retry_limit to the initializer (#{caller.first})")
      @data[:retry_limit] ||= DEFAULT_RETRY_LIMIT
    end

    def inspect
      vars = instance_variables.inject({}) do |accum, var|
        accum.merge!(var.to_sym => instance_variable_get(var))
      end
      if vars[:'@data'][:headers].has_key?('Authorization')
        vars[:'@data'] = vars[:'@data'].dup
        vars[:'@data'][:headers] = vars[:'@data'][:headers].dup
        vars[:'@data'][:headers]['Authorization'] = REDACTED
      end
      inspection = '#<Excon::Connection:'
      inspection << (object_id << 1).to_s(16)
      vars.each do |key, value|
        inspection << ' ' << key.to_s << '=' << value.inspect
      end
      inspection << '>'
      inspection
    end

    private

    def detect_content_length(body)
      if body.is_a?(String)
        if FORCE_ENC
          body.force_encoding('BINARY')
        end
        body.length
      elsif body.respond_to?(:size)
        # IO object: File, Tempfile, etc.
        body.size
      else
        begin
          File.size(body) # for 1.8.7 where file does not have size
        rescue
          0
        end
      end
    end

    def response(datum={})
      unless datum.has_key?(:response)
        datum[:response] = {
          :body       => '',
          :headers    => {},
          :status     => socket.read(12)[9, 11].to_i,
          :remote_ip  => socket.remote_ip
        }
        socket.readline # read the rest of the status line and CRLF

        until ((data = socket.readline).chop!).empty?
          key, value = data.split(/:\s*/, 2)
          datum[:response][:headers][key] = ([*datum[:response][:headers][key]] << value).compact.join(', ')
          if key.casecmp('Content-Length') == 0
            content_length = value.to_i
          elsif (key.casecmp('Transfer-Encoding') == 0) && (value.casecmp('chunked') == 0)
            transfer_encoding_chunked = true
          end
        end

        unless (['HEAD', 'CONNECT'].include?(datum[:method].to_s.upcase)) || NO_ENTITY.include?(datum[:response][:status])

          # check to see if expects was set and matched
          expected_status = !datum.has_key?(:expects) || [*datum[:expects]].include?(datum[:response][:status])

          # if expects matched and there is a block, use it
          if expected_status && datum.has_key?(:response_block)
            if transfer_encoding_chunked
              # 2 == "/r/n".length
              while (chunk_size = socket.readline.chop!.to_i(16)) > 0
                datum[:response_block].call(socket.read(chunk_size + 2).chop!, nil, nil)
              end
              socket.read(2)
            elsif remaining = content_length
              while remaining > 0
                datum[:response_block].call(socket.read([datum[:chunk_size], remaining].min), [remaining - datum[:chunk_size], 0].max, content_length)
                remaining -= datum[:chunk_size]
              end
            else
              while remaining = socket.read(datum[:chunk_size])
                datum[:response_block].call(remaining, remaining.length, content_length)
              end
            end
          else # no block or unexpected status
            if transfer_encoding_chunked
              while (chunk_size = socket.readline.chop!.to_i(16)) > 0
                datum[:response][:body] << socket.read(chunk_size + 2).chop! # 2 == "/r/n".length
              end
              socket.read(2) # 2 == "/r/n".length
            elsif remaining = content_length
              while remaining > 0
                datum[:response][:body] << socket.read([datum[:chunk_size], remaining].min)
                remaining -= datum[:chunk_size]
              end
            else
              datum[:response][:body] << socket.read
            end
          end
        end
      end

      datum[:stack].response_call(datum)
    rescue => error
      case error
      when Excon::Errors::HTTPStatusError, Excon::Errors::Timeout
        raise(error)
      else
        raise(Excon::Errors::SocketError.new(error))
      end
    end

    def socket
      sockets[@socket_key] ||= if @data[:scheme] == HTTPS
        Excon::SSLSocket.new(@data)
      else
        Excon::Socket.new(@data)
      end
    end

    def sockets
      Thread.current[:_excon_sockets] ||= {}
    end

    def setup_proxy(proxy)
      case proxy
      when String
        uri = URI.parse(proxy)
        unless uri.host and uri.port and uri.scheme
          raise Excon::Errors::ProxyParseError, "Proxy is invalid"
        end
        {
          :host       => uri.host,
          :password   => uri.password,
          :port       => uri.port.to_s,
          :scheme     => uri.scheme,
          :user       => uri.user
        }
      else
        proxy
      end
    end

  end
end
