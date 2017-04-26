require 'thread'

require 'concurrent'
require 'promise'

class Promise
  def wait
    pending = Thread.current[:pending_batches]
    Thread.current[:pending_batches] = []
    pending.each(&:dispatch)
  end
end

class BatchPromise < Promise
  def initialize(batch_load, cache)
    @trigger = Promise.new
    @dispatch = @trigger.then { callback }
    @dispatched = false
    @queue = Concurrent::Array.new
    @batch_load = batch_load
    @cache = cache
    @after_dispatch = Promise.new
    Thread.current[:pending_batches].unshift(self)
  end

  def then(on_fulfill = nil, on_reject = nil, &block)
    @dispatch.then(on_fulfill, on_reject, &block)
  end

  def dispatch
    @dispatched = true
    @trigger.fulfill
    self
  end

  def dispatched?
    @dispatched
  end

  attr_reader :after_dispatch

  def queue(key)
    if @dispatched
      raise StandardError, "Cannot queue elements after batch is dispatched. Queued key: #{key}"
    end

    @queue.push(key)

    @dispatch.then do |values|
      unless values.key?(key)
        raise StandardError, "Promise didn't resolve a key: #{key}\nResolved keys: #{values.keys.join(' ')}"
      end

      values[key]
    end
  end

  def callback
    @running = true
    keys = @queue - @cache.keys
    result = @batch_load.call(keys)
    @after_dispatch.fulfill
    if result.is_a?(Promise)
      result.then do |values|
        handle_result(keys, values)
      end
    else
      Promise.resolve(handle_result(keys, result))
    end
  end

  def handle_result(keys, values)
    unless values.is_a?(Array) || values.is_a?(Hash)
      raise TypeError, 'Dataloader must be constructed with a block which accepts ' \
        'Array<key> and returns Array<value> or Hash<key, value>. ' \
        "Function returned instead: #{values}."
    end

    if keys.size != values.size
      raise TypeError, 'Dataloader must be instantiated with function that returns Array or Hash ' \
        'of the same size as provided to it Array of keys' \
        "\n\nProvided keys:\n#{keys}" \
        "\n\nReturned values:\n#{values}"
    end

    values = Hash[keys.zip(values)] if values.is_a?(Array)

    values
  end
end

class Dataloader
  VERSION = "0.0.0"

  def initialize(options = {}, &batch_load)
    unless block_given?
      raise TypeError, 'Dataloader must be constructed with a block which accepts ' \
        'Array<key> and returns Array<value> or Hash<key, value>'
    end

    @options = options
    @batch_load = batch_load

    @promises = Concurrent::Map.new
    @values = Concurrent::Map.new

    Thread.current[:pending_batches] ||= []
  end

  def self.wait
    Thread.current[:pending_batches].each(&:dispatch)
  end

  def log(*args)
    puts "[#{@options[:name]}] #{args.join(' ')}"
  end

  def load(key)
    if key.nil?
      raise TypeError, "The loader.load() must be called with a key, but got: #{key}"
    end

    cache_key_fn = @options.fetch(:key, ->(key) { key })

    cache_key = if cache_key_fn.respond_to?(:call)
                  cache_key_fn.call(key)
                else
                  key[cache_key_fn]
                end

    @promises.compute_if_absent(cache_key) do
      batch = batch_promise
      batch.queue(key)
    end
  end

  def batch_promise
    if @batch_promise.nil? || @batch_promise.dispatched?
      new_promise = create_batch_promise
      if @batch_promise
        Thread.start do
          sleep 0.05
          new_promise.dispatch
        end
      end
      @batch_promise = new_promise
    end

    @batch_promise
  end

  def create_batch_promise
    BatchPromise.new(@batch_load, @values)
  end

  def load_many(keys)
    unless keys.is_a?(Array)
      raise TypeError, "The loader.load_many() must be called with a Array<key>, but got: #{key}"
    end

    Promise.all(keys.map(&method(:load)))
  end

  def dispatch
    @batch_promise.dispatch if @batch_promise && !@batch_promise.dispatched?
  end
end