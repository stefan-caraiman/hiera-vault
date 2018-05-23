#
# TODO:
#   - Figure out why this works with puppet apply and not puppet agent -t
#   - Look into caching values
#   - Test the options: default_field, default_field_behavior, and default_field_parse
#

Puppet::Functions.create_function(:hiera_vault) do

  begin
    require 'json'
  rescue LoadError => e
    raise Puppet::DataBinding::LookupError, "[hiera-vault] Must install json gem to use hiera-vault backend"
  end
  begin
    require 'vault'
  rescue LoadError => e
    raise Puppet::DataBinding::LookupError, "[hiera-vault] Must install vault gem to use hiera-vault backend"
  end

  dispatch :lookup_key do
    param 'Variant[String, Numeric]', :key
    param 'Hash', :options
    param 'Puppet::LookupContext', :context
  end

  def lookup_key(key, options, context)

    if confine_keys = options['confine_to_keys']
      raise ArgumentError, '[hiera-vault] confine_to_keys must be an array' unless confine_keys.is_a?(Array)

      begin
        confine_keys = confine_keys.map { |r| Regexp.new(r) }
      rescue StandardError => e
        raise Puppet::DataBinding::LookupError, "[hiera-vault] creating regexp failed with: #{e}"
      end

      regex_key_match = Regexp.union(confine_keys)

      unless key[regex_key_match] == key
        context.explain { "[hiera-vault] Skipping hiera_vault backend because key does not match confine_to_keys" }
        context.not_found
      end
    end

    result = vault_get(key, options, context)

    return result
  end


  def vault_get(key, options, context)

    if ! ['string','json',nil].include?(options['default_field_parse'])
      raise ArgumentError, "[hiera-vault] invalid value for default_field_parse: '#{options['default_field_behavior']}', should be one of 'string','json'"
    end

    if ! ['ignore','only',nil].include?(options['default_field_behavior'])
      raise ArgumentError, "[hiera-vault] invalid value for default_field_behavior: '#{options['default_field_behavior']}', should be one of 'ignore','only'"
    end

    begin
      vault = Vault::Client.new

      vault.configure do |config|
        config.address = options['address'] unless options['address'].nil?
        config.token = options['token'] unless options['token'].nil?
        config.ssl_pem_file = options['ssl_pem_file'] unless options['ssl_pem_file'].nil?
        config.ssl_verify = options['ssl_verify'] unless options['ssl_verify'].nil?
        config.ssl_ca_cert = options['ssl_ca_cert'] if config.respond_to? :ssl_ca_cert
        config.ssl_ca_path = options['ssl_ca_path'] if config.respond_to? :ssl_ca_path
        config.ssl_ciphers = options['ssl_ciphers'] if config.respond_to? :ssl_ciphers
      end

      if vault.sys.seal_status.sealed?
        raise Puppet::DataBinding::LookupError, "[hiera-vault] vault is sealed"
      end

      context.explain { "[hiera-vault] Client configured to connect to #{vault.address}" }
    rescue StandardError => e
      vault = nil
      raise Puppet::DataBinding::LookupError, "[hiera-vault] Skipping backend. Configuration error: #{e}"
    end

    answer = nil

    generic = options['mounts']['generic'].dup
    generic ||= [ '/secret' ]

    # Only generic mounts supported so far
    generic.each do |mount|
      path = context.interpolate(mount) + key
      context.explain { "[hiera-vault] Looking in path #{path}" }

      begin
        secret = vault.logical.read(path)
      rescue Vault::HTTPConnectionError
        context.explain { "[hiera-vault] Could not connect to read secret: #{path}" }
      rescue Vault::HTTPError => e
        context.explain { "[hiera-vault] Could not read secret #{path}: #{e.errors.join("\n").rstrip}" }
      end

      next if secret.nil?

      context.explain { "[hiera-vault] Read secret: #{key}" }
      if (options['default_field'] && ['ignore', nil].include?(options['default_field_behavior'])) ||
         (options['default_field'] && secret.data.has_key?(options['default_field'].to_sym) && secret.data.length == 1)

        return nil if ! secret.data.has_key?(options['default_field'].to_sym)

        new_answer = secret.data[options['default_field'].to_sym]

        if options['default_field_parse'] == 'json'
          begin
            new_answer = JSON.parse(new_answer)
          rescue JSON::ParserError => e
            context.explain { "[hiera-vault] Could not parse string as json: #{e}" }
          end
        end

      else
        # Turn secret's hash keys into strings
        new_answer = secret.data.inject({}) { |h, (k, v)| h[k.to_s] = v; h }
      end

#      context.explain {"[hiera-vault] Data: #{new_answer}:#{new_answer.class}" }

      if ! new_answer.nil?
        answer = new_answer
        break
      end
    end

    return answer
  end
end
