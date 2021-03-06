require 'dotenv/rails-now'
require 'http_accept_language'
require 'paperclip'
require 'validates_email_format_of'
require 'validates_phone_format_of'
require 'rails_i18n'
require 'jt-rails-meta'
require 'jt-rails-generator-user'
require 'jt-rails-tokenizable'
require 'jt-rails-address'
require 'jt-rails-enum'
require 'oj'
require 'oj_mimic_json'
require 'validates_timeliness'

require 'yaml'

module JTRailsToolbox

	class Engine < ::Rails::Engine
		
		initializer "jt-rails-toolbox" do |app|
			@params = {}

			if ::File.exists?('config/jt-toolbox.yml')
				yaml = YAML.load(ERB.new(File.read('config/jt-toolbox.yml'), 0, '<>').result)
				if yaml
					@params = yaml['shared'] || {}
					@params.deep_merge!(yaml[Rails.env.to_s] || {})
				end
			end

			process_params
			configure_sidekiq(app)
			configure_exception_notification(app)
			configure_mail(app)
			configure_paperclip(app)
		end

		def process_params
			@params['files'] ||= {}
			if @params['files']['folder'].nil?
				@params['files']['folder'] = '/upload'
			else
				# Remove end slash
				@params['files']['folder'].sub!(/\/$/, '')

				if !@params['files']['folder'].start_with?('/')
					@params['files']['folder'] = "/#{@params['files']['folder']}"
				end
			end

			@params['mail'] ||= {}
			@params['mail']['delivery_method'] ||= :test
			@params['mail']['delivery_method'] = @params['mail']['delivery_method'].to_sym

			@params['mail']['smtp_settings'] ||= {}
			settings = @params['mail']['smtp_settings'].dup
			@params['mail']['smtp_settings'] = {}
			for key, value in settings
				@params['mail']['smtp_settings'][key.to_sym] = value
			end

			@params['hosts'] ||= {}
			@params['hosts']['host'] ||= 'http://localhost:3000'
			@params['hosts']['asset_host'] ||= @params['hosts']['host']
			@params['hosts']['cdn_host'] ||= @params['hosts']['asset_host']

			# Should avoid namespace with Redis
			# http://www.mikeperham.com/2015/09/24/storing-data-with-redis/
			@params['sidekiq'] ||= {}
			@params['sidekiq']['disable'] ||= false
			@params['sidekiq']['redis_url'] ||= "redis://localhost:6379/0"
			@params['sidekiq']['namespace'] ||= "#{Rails.application.class.parent_name.parameterize}#{Rails.env.production? ? '' : "-#{Rails.env.to_s}"}"
		end

		def configure_exception_notification(app)
			return if @params['exception'].nil?

			if @params['exception']['airbrake']
				puts "[JT-RAILS-TOOLBOX] Airbrake support was remove in 2.8 version"
			end

			require 'exception_notification'
			require 'exception_notification/rails'
			require 'exception_notification/sidekiq' unless sidekiq_disabled?

			ExceptionNotification.configure do |config|
				config.ignored_exceptions += %w{ActionController::InvalidCrossOriginRequest ActionController::InvalidAuthenticityToken}

				if @params['exception']['slack']
					config.add_notifier :slack, {
						webhook_url: @params['exception']['slack']['webhook_url'],
					}
				end

				if @params['exception']['exception_recipients']
					config.add_notifier :email, {
						email_prefix: @params['exception']['email_prefix'],
						sender_address: @params['exception']['sender_address'],
						exception_recipients: @params['exception']['exception_recipients']
					}
				end
			end
		end

		def configure_mail(app)
			ActionMailer::Base.delivery_method = @params['mail']['delivery_method']
			ActionMailer::Base.smtp_settings = @params['mail']['smtp_settings']
			ActionMailer::Base.default_url_options[:host] = @params['hosts']['host']
			ActionMailer::Base.default from: @params['mail']['from']
			ActionMailer::Base.asset_host = @params['hosts']['asset_host']
		end

		def configure_paperclip(app)
			# Strip meta data from images
			Paperclip::Attachment.default_options[:convert_options] = { all: '-strip' }

			# Params in url are bad for SEO, it's better to use fingerprint for having an unique url
			Paperclip::Attachment.default_options[:use_timestamp] = false

			path = @params['files']['folder'].to_s
			path = "/#{path}" if !path.start_with?('/')
			path += '/' if !path.end_with?('/')
			path += ":class/:attachment/:id/:style/:fingerprint.:content_type_extension"

			Paperclip::Attachment.default_options[:path] = ":rails_root/public#{path}"
			Paperclip::Attachment.default_options[:url] = "#{@params['hosts']['cdn_host']}#{path}"

			ActionController::Base.asset_host = @params['hosts']['asset_host']
			app.config.action_controller.asset_host = @params['hosts']['asset_host']
		end

		def configure_sidekiq(app)
			return if sidekiq_disabled?

			require 'sidekiq'

			options = {
				url: @params['sidekiq']['redis_url'],
				namespace: @params['sidekiq']['namespace']
			}

			if @params['sidekiq']['network_timeout'].present?
				options[:network_timeout] = @params['sidekiq']['network_timeout'].to_i
			end

			Sidekiq.configure_server do |config|
				config.redis = options
			end

			Sidekiq.configure_client do |config|
				config.redis = options
			end

			ActiveJob::Base.queue_adapter = :sidekiq
		end

		def sidekiq_disabled?
			@params['sidekiq']['disable'] == true
		end

	end
		
end