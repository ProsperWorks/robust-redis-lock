require 'redis'
require 'securerandom'

class Redis::Lock
  NAMESPACE = 'redis:lock'

  require 'robust-redis-lock/script'

  attr_reader :key
  attr_reader :recovery_data

  class << self
    attr_accessor :redis
    attr_accessor :timeout
    attr_accessor :sleep
    attr_accessor :expire
  end

  self.timeout    = 60
  self.expire     = 60
  self.sleep      = 0.1

  def initialize(key, options={})
    @options = options

    @key = key

    @redis    = @options[:redis] || self.class.redis
    raise "redis cannot be nil" if @redis.nil?

    @timeout    = @options[:timeout]    || self.class.timeout
    @expire     = @options[:expire]     || self.class.expire
    @sleep      = @options[:sleep]      || self.class.sleep
    @token      = @options[:token]
  end

  def synchronize
    begin
      lock
    rescue Recovered
    end

    begin
      yield
    ensure
      unlock
    end
  end

  def lock(options={})
    locked   = false
    start_at = now

    while now - start_at < @timeout
      break if locked = try_lock(options)
      sleep @sleep.to_f
    end

    raise Timeout.new(self)   unless locked
    raise Recovered.new(self) if locked == :recovered
  end

  def try_lock(options={})
    raise "recovery_data must be a string" if options[:recovery_data] && !options[:recovery_data].is_a?(String)

    # This script loading is not thread safe (touching a class variable), but
    # that's okay, because the race is harmless.
    @@lock_script ||= Script.new <<-LUA
        local key = KEYS[1]
        local bare_key = ARGV[1]
        local now = tonumber(ARGV[2])
        local expires_at = tonumber(ARGV[3])
        local recovery_data = ARGV[4]
        local next_token = ARGV[5]

        local prev_expires_at = tonumber(redis.call('hget', key, 'expires_at'))
        if prev_expires_at and prev_expires_at > now then
          return {'locked', nil, nil}
        end

        redis.call('hset', key, 'expires_at', expires_at)

        local return_value = nil
        if prev_expires_at then
          return_value =  {'recovered', next_token, redis.call('hget', key, 'recovery_data')}
        else
          redis.call('hset', key, 'recovery_data', recovery_data)
          return_value =  {'acquired', next_token, nil}
        end

        redis.call('hset', key, 'token', next_token)
        return return_value
    LUA
    next_token = SecureRandom.uuid
    result, token, recovery_data = @@lock_script.eval(@redis,
                                                      :keys => [namespaced_key],
                                                      :argv => [@key, now.to_i, now.to_i + @expire, options[:recovery_data], next_token])

    case result
    when 'locked'
      false
    when 'acquired'
      @token = token
      true
    when 'recovered'
      @token = token
      @recovery_data = recovery_data
      :recovered
    end
  end

  def unlock
    raise Redis::Lock::LostLock.new(self) unless try_unlock
  end

  def try_unlock
    raise NotLocked.new('unlock', self) unless @token

    # Since it's possible that the operations in the critical section took a long time,
    # we can't just simply release the lock. The unlock method checks if @expire_at
    # remains the same, and do not release when the lock timestamp was overwritten.
    @@unlock_script ||= Script.new <<-LUA
        local key = KEYS[1]
        local bare_key = ARGV[1]
        local token = ARGV[2]

        if redis.call('hget', key, 'token') == token then
          redis.call('del', key)
          return true
        else
          return false
        end
    LUA
    !!@@unlock_script.eval(@redis, :keys => [namespaced_key], :argv => [@key, @token]).tap do
      @token = nil
    end
  end

  def extend
    raise Redis::Lock::LostLock.new(self) unless try_extend
  end

  def try_extend
    raise NotLocked.new('extend', self) unless @token

    @@extend_script ||= Script.new <<-LUA
        local key = KEYS[1]
        local bare_key = ARGV[1]
        local expires_at = tonumber(ARGV[2])
        local token = ARGV[3]
        local next_token = ARGV[4]

        if redis.call('hget', key, 'token') == token then

          redis.call('hset', key, 'expires_at', expires_at)
          redis.call('hset', key, 'token', next_token)

          return { next_token, redis.call('hget', key, 'recovery_data') }
        else
          return false
        end
    LUA
    next_token = SecureRandom.uuid
    result = @@extend_script.eval(@redis, :keys => [namespaced_key], :argv => [@key, now.to_i + @expire, @token, next_token])

    if result
      @token, @recovery_data = result
      true
    else
      false
    end
  end

  def now
    Time.now
  end

  def ==(other)
    @key == other.key
  end

  def to_s
    @key
  end

  def namespaced_key
    NAMESPACE + ':' + @key
  end

  class Error < RuntimeError
    attr_reader :lock

    def initialize(lock)
      @lock = lock
    end
  end

  class LostLock < Error
    def message
      "The following lock was lost while trying to modify: #{@lock}"
    end
  end

  class Recovered < Error
    def message
      "The following lock was recovered: #{@lock}"
    end
  end

  class Timeout < Error
    def message
      "The following lock timed-out waiting to get aquired: #{@lock}"
    end
  end

  class NotLocked < Error
    def initialize(operation, lock)
      @operation = operation
      @lock = lock
    end

    def message
      "Trying to #{@operation} a lock has not been aquired: #{@lock}"
    end
  end
end
