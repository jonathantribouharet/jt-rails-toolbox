require 'dotenv/rails-now'
require 'http_accept_language'
require 'paperclip'
require 'validates_email_format_of'
require 'validates_phone_format_of'
require 'rails_i18n'
require 'jt-rails-meta'
require 'jt-rails-generator-user'
require 'jt-rails-tokenizable'

require 'yaml'

module JTRailsToolbox

	class Engine < ::Rails::Engine
		
		initializer "jt-rails-toolbox" do |app|
			@params = {}

			if ::File.exists?('config/jt-toolbox.yml')
				yaml = YAML::load(ERB.new(File.read('config/jt-toolbox.yml'), 0, '<>').result)
				if yaml
					@params = yaml[Rails.env.to_s] || {}
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

				require 'airbrake'
				require 'airbrake/sidekiq/error_handler' unless sidekiq_disabled?

				Airbrake.configure do |c|
					if @params['exception']['airbrake']['host']
						c.host = @params['exception']['airbrake']['host']
					end

					c.project_id = @params['exception']['airbrake']['project_id']
					c.project_key = @params['exception']['airbrake']['project_key']

					c.environment = Rails.env

					if @params['exception']['airbrake']['ignore_environments']
						c.ignore_environments = @params['exception']['airbrake']['ignore_environments']
					else
						c.ignore_environments = %w(development test)
					end
				end

				# Default ignored exceptions in Exception Notification
				exceptions_to_ignore = %w{ActiveRecord::RecordNotFound Mongoid::Errors::DocumentNotFound AbstractController::ActionNotFound ActionController::RoutingError ActionController::UnknownFormat ActionController::UrlGenerationError}

				# Additionnal exceptions to ignore
				exceptions_to_ignore.push *%w{ActionController::InvalidCrossOriginRequest ActionController::InvalidAuthenticityToken}

				Airbrake.add_filter do |notice|
					if notice[:errors].any? { |error| exceptions_to_ignore.include?(error[:type]) }
						notice.ignore!
					end
				end
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

			path = "#{@params['files']['folder']}/:class/:attachment/:id/:style/:fingerprint.:content_type_extension"

			Paperclip::Attachment.default_options[:path] = ":rails_root/public/#{path}"
			Paperclip::Attachment.default_options[:url] = "#{@params['hosts']['cdn_host']}#{path}"

			ActionController::Base.asset_host = @params['hosts']['asset_host']
			app.config.action_controller.asset_host = @params['hosts']['asset_host']
		end

		def configure_sidekiq(app)
			return if sidekiq_disabled?

			require 'sidekiq'

			Sidekiq.configure_server do |config|
				config.redis = { url: @params['sidekiq']['redis_url'], namespace: @params['sidekiq']['namespace'] }
			end

			Sidekiq.configure_client do |config|
				config.redis = { url: @params['sidekiq']['redis_url'], namespace: @params['sidekiq']['namespace'] }
			end

			ActiveJob::Base.queue_adapter = :sidekiq
		end

		def sidekiq_disabled?
			@params['sidekiq']['disable'] == true
		end

	end
		
end