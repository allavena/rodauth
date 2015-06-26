class Roda
  module RodaPlugins
    module Rodauth
      def self.load_dependencies(app)
        app.plugin :render
        app.plugin :h
      end

      def self.configure(app, &block)
        app.opts[:rodauth] ||= Class.new(Auth)
        app.opts[:rodauth].configure(&block)
      end

      DSL_META_TYPES = [:auth, :auth_block, :auth_value].freeze
      FEATURES = {}

      class Feature < Module
        DSL_META_TYPES.each do |meth|
          name = :"#{meth}_methods"
          define_method(name) do |*v|
            iv = :"@#{name}"
            existing = instance_variable_get(iv) || []
            if v.empty?
              existing
            else
              instance_variable_set(iv, existing + v)
            end
          end
        end

        attr_accessor :feature_name

        def self.define(name)
          feature = new
          feature.feature_name = name
          FEATURES[name] = feature
        end

        def route(v)
          meth = :"#{feature_name}_route"
          define_method(meth){v}
          auth_value_methods meth
        end
        
        [:get, :post, :route].each do |meth|
          define_method("#{meth}_block") do |&block|
            if block
              instance_variable_set("@#{meth}_block", block)
            else
              instance_variable_get("@#{meth}_block")
            end
          end
        end
      end

      class Auth
        class << self
          attr_reader :features
          attr_reader :route_block_methods
        end

        def self.inherited(subclass)
          super
          subclass.instance_exec do
            @features = []
            @route_block_methods = []
          end
        end

        def self.configure(&block)
          DSL.new(self, &block)
        end

        def self.freeze
          @features.freeze
          @route_block_methods.freeze
          super
        end

        def route_block_methods
          self.class.route_block_methods
        end
      end

      class DSL
        def def_auth_method(meth)
          define_sclass_method(meth) do |&block|
            _def_auth_method(meth, &block)
          end
        end

        def def_auth_value_method(meth)
          define_sclass_method(meth) do |*v, &block|
            v = v.first
            block ||= proc{v}
            _def_auth_method(meth, &block)
          end
        end

        def def_auth_block_method(meth)
          define_sclass_method(meth) do |&block|
            _def_auth_method(meth){block}
          end
        end

        def initialize(auth, &block)
          @auth = auth
          load_feature(:base)
          instance_exec(&block)
        end

        def enable(*features)
          new_features = features - @auth.features
          new_features.each{|f| load_feature(f)}
          @auth.features.concat(new_features)
        end

        private

        def _def_auth_method(meth, &block)
          @auth.send(:define_method, meth, &block)
        end

        def define_sclass_method(meth, &block)
          (class << self; self end).send(:define_method, meth, &block)
        end

        def load_feature(feature_name)
          require "roda/plugins/rodauth/#{feature_name}"
          feature = FEATURES[feature_name]

          DSL_META_TYPES.each do |type|
            feature.send(:"#{type}_methods").each{|m| send(:"def_#{type}_method", m)}
          end

          if get_block = feature.get_block
            def_auth_block_method :"#{feature_name}_get_block"
            _def_auth_method(:"#{feature_name}_get_block"){get_block}
          end

          if post_block = feature.post_block
            def_auth_block_method :"#{feature_name}_post_block"
            _def_auth_method(:"#{feature_name}_post_block"){post_block}
          end

          route_block = feature.route_block
          if route_block || (get_block && post_block)
            def_auth_block_method :"#{feature_name}_route_block"
            route_block ||= proc do |r|
              auth = rodauth
              r.is auth.send(:"#{feature_name}_route") do
                r.get do
                  instance_exec(r, &rodauth.send(:"#{feature_name}_get_block"))
                end

                r.post do
                  instance_exec(r, &rodauth.send(:"#{feature_name}_post_block"))
                end
              end
            end
            _def_auth_method(:"#{feature_name}_route_block"){route_block}
            @auth.route_block_methods << :"#{feature_name}_route_block"
          end

          @auth.include(feature)
        end
      end

      module InstanceMethods
        def rodauth
          @_rodauth ||= self.class.rodauth.new(self)
        end
      end

      module ClassMethods
        def rodauth
          opts[:rodauth]
        end

        def freeze
          rodauth.freeze
          super
        end
      end

      module RequestMethods
        def rodauth
          auth = scope.rodauth
          auth.route_block_methods.each do |meth|
            scope.instance_exec(self, &auth.send(meth))
          end
        end
      end
    end

    register_plugin(:rodauth, Rodauth)
  end
end
