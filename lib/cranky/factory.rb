module Cranky
  class FactoryBase

    TRAIT_METHOD_REGEXP = /apply_trait_(\w+)_to_(\w+)/.freeze

    def initialize
      # Factory jobs can be nested, i.e. a factory method can itself invoke another factory method to
      # build a dependent object. In this case jobs the jobs are pushed into a pipeline and executed
      # in a last in first out order.
      @pipeline = []
      @n = 0
      @errors = []
      @fixtures = {}
      @stats = {}
    end

    def build(what, overrides={})
      item = crank_it(what, overrides)
      call_after_build(what, item)

      item
    end

    def create(what, overrides={})
      item = build(what, overrides)
      Array(item).each do |i|
        call_before_create(what, i)
        (i.persisted? || i.save) && call_after_create(what, i)
      end
      item
    end

    def create!(what, overrides={})
      item = build(what, overrides)
      Array(item).each do |i|
        call_before_create(what, i)
        i.save! unless i.persisted?
        call_after_create(what, i)
      end
      item
    end

    # Reset the factory instance, clear all instance variables
    def reset
      self.instance_variables.each do |var|
        instance_variable_set(var, nil)
      end
      initialize
    end

    def attributes_for(what, attrs={})
      build(what, attrs.merge(:_return_attributes => true))
    end

    # Can be left in your tests as an alternative to build and to warn if your factory method
    # ever starts producing invalid instances
    def debug(*args)
      item = build(*args)
      invalid_item = Array(item).find(&:invalid?)
      if invalid_item
        if invalid_item.errors.respond_to?(:messages)
          errors = invalid_item.errors.messages
        else
          errors = invalid_item.errors
        end
        raise "Oops, the #{invalid_item.class} created by the Factory has the following errors: #{errors}"
      end
      item
    end

    # Same thing for create
    def debug!(*args)
      item = debug(*args)
      item.save
      item
    end

    # Look for errors in factories and (optionally) their traits.
    # Parameters:
    # factory_names - which factories to lint; omit for all factories
    # options:
    #   traits : true - to lint traits as well as factories
    def lint!(factory_names: nil, traits: false)
      factories_to_lint = Array(factory_names || self.factory_names)
      strategy = traits ? :factory_and_traits : :factory
      Linter.new(self, factories_to_lint, strategy).lint!
    end

    def factory_names
      public_methods(false).reject {|m| TRAIT_METHOD_REGEXP === m  }.sort
    end

    def traits_for(factory_name)
      regexp = /^apply_trait_(\w+)_to_#{factory_name}$/.freeze
      available_methods = private_methods(false) + public_methods(false)
      trait_methods = available_methods.select {|m| regexp === m  }
      trait_methods.map {|m| regexp.match(m)[1] }
    end

    def fetch(*args)
      if block_given?
        options.fetch(*args, &Proc.new)
      else
        options.fetch(*args)
      end
    end
    
    def reload_fixture
      @fixtures.values.each(&:reload)
    end

    def load_fixture(filename)
      return unless File.exist?(filename)

      puts '================= load fixture =================='
      data = YAML.load(File.read(filename))
      data.each do |f|
        p f
        overrides = JSON.parse(f[:overrides])
        # overrides[:_skip_fixture] = true
        @fixtures[f[:digest]] ||= crank!(f[:what], overrides)
        if f[:what] == :organization
          p f[:digest]
          p f[:overrides]
          p @fixtures[f[:digest]]
        end
      end
      puts '================= fixture loaded =================='
    end

    def dump_stats(filename)
      return if @stats.blank?

      File.open(filename, 'w') do |f|
        f.write(@stats.values.sort_by { |v| -v[:count] }.to_yaml)
      end
    end

    private

      def call_after_build(what, item)
        method_name = "after_build_#{what}"
        respond_to?(method_name, true) && send(method_name, item)
      end

      def call_before_create(what, item)
        method_name = "before_create_#{what}"
        respond_to?(method_name, true) && send(method_name, item)
      end

      def call_after_create(what, item)
        method_name = "after_create_#{what}"
        respond_to?(method_name, true) && send(method_name, item)
      end

      def apply_traits(what, item)
        Array(options[:traits]).each do |t|
          trait_method_name = "apply_trait_#{t}_to_#{what}"
          respond_to?(trait_method_name, true) || fail("Invalid trait '#{t}'! No method '#{trait_method_name}' is defined.")
          send(trait_method_name, item)
        end

        item
      end

      def n
        @n += 1
      end

      # Execute the requested factory method, crank out the target object!
      def crank_it(what, overrides)
        digest = Digest::SHA256.hexdigest({ what:, overrides: }.to_json)

        if what.to_s =~ /(.*)_attrs$/
          what = $1
          overrides = overrides.merge(:_return_attributes => true)
        end
        if overrides[:_return_attributes].nil?
          # p what
          # p overrides
          # puts '---'

          if @fixtures[digest].present?
            # if what == :organization
            #   p digest
            #   p @fixtures[digest]
            # end

            return @fixtures[digest]
          end
        end
        item = "TBD"
        new_job(what, overrides) do
          item = self.send(what)        # Invoke the factory method
          item = apply_traits(what, item)
        end
        count = 1
        current = @stats[digest]
        if current.present?
          count = current[:count] + 1
        end
        @stats[digest] = { what:, overrides: overrides.to_json, digest:, count: }
        item
      end

      # This method actually makes the required object instance, it gets called by the users factory
      # method, where the name 'define' makes more sense than it does here!
      def define(defaults={})
        current_job.defaults = defaults
        current_job.execute
      end

      def inherit(what, overrides={})
        overrides = overrides.merge(options)
        overrides = overrides.merge(:_return_attributes => true) if current_job.return_attributes
        build(what, overrides)
      end

      def current_job
        @pipeline.last
      end

      # Returns a hash containing any top-level overrides passed in when the current factory was invoked
      def options
        current_job.overrides
      end

      # Adds a new job to the pipeline then yields to the caller to execute it
      def new_job(what, overrides)
        @pipeline << Job.new(what, overrides)
        yield
        @pipeline.pop
      end

  end

  class Factory < FactoryBase
  end

end
