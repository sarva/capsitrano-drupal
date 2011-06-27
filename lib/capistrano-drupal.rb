Capistrano::Configuration.instance(:must_exist).load do

  require 'digest/md5'
  require 'capistrano/recipes/deploy/scm'
  require 'capistrano/recipes/deploy/strategy'
  
  # =========================================================================
  # These variables may be set in the client capfile if their default values
  # are not sufficient.
  # =========================================================================

  set :salt, ""
  set :scm, :git
  set :deploy_via, :remote_cache
  set :repository_cache, "git-cache"
  _cset :branch, "master"
  set :git_enable_submodules, true
  set :runner_group, "www-data"
  
  set(:deploy_to) { "/var/www/#{application}" }
  set(:repository_cache_path) { "#{shared_path}/#{repository_cache}" }
  set :shared_children, ['files', 'private', 'backups']

  set(:db_name) { "prod_#{application}" }  
  set(:db_username) { "prod_#{application}" }  
  set(:db_password) { Digest::MD5.hexdigest("#{salt}prod#{application}") }
  
  after "deploy:setup", "drush:createdb"
  before "drupal:symlink_shared", "drupal:init_settings"
  before "drush:updatedb", "drush:backupdb"
  after "deploy:symlink", "drupal:symlink_shared"
  after "deploy:symlink", "drush:updatedb"
  after "deploy:symlink", "drush:cache_clear"
  after "deploy:symlink", "git:push_deploy_tag"
  after "deploy:cleanup", "git:cleanup_deploy_tag"
  
  namespace :deploy do
    desc <<-DESC
      Prepares one or more servers for deployment. Before you can use any \
      of the Capistrano deployment tasks with your project, you will need to \
      make sure all of your servers have been prepared with `cap deploy:setup'. When \
      you add a new server to your cluster, you can easily run the setup task \
      on just that server by specifying the HOSTS environment variable:

        $ cap HOSTS=new.server.com deploy:setup

      It is safe to run this task on servers that have already been set up; it \
      will not destroy any deployed revisions or data.
    DESC
    task :setup, :except => { :no_release => true } do
      dirs = [deploy_to, releases_path, shared_path]
      dirs += shared_children.map { |d| File.join(shared_path, d) }
      run "#{try_sudo} mkdir -p #{dirs.join(' ')}"
      run "#{try_sudo} chgrp -R #{runner_group} #{dirs.join(' ')}"
      run "#{try_sudo} chmod -R g+w #{dirs.join(' ')}"
    end
  end
  
  namespace :drupal do
    desc "Symlink settings and files to shared directory. This allows the settings.php and \
      and sites/default/files directory to be correctly linked to the shared directory on a new deployment."
    task :symlink_shared do
      ["files", "private", "settings.php"].each do |asset|
        run "rm -rf #{release_path}/#{asset} && ln -nfs #{shared_path}/#{asset} #{release_path}/sites/default/#{asset}"
      end
    end

    desc "Ensure settings.php"
    task :init_settings do
      run "if [ ! -f #{shared_path}/settings.php ]; then cp #{release_path}/sites/default/default.settings.php #{shared_path}/settings.php; fi;"
      run "chmod 664 #{shared_path}/settings.php"
      run "sed -i -e 's/%db/#{db_name}/g' #{shared_path}/settings.php"
      run "sed -i -e 's/%user/#{db_username}/g' #{shared_path}/settings.php"
      run "sed -i -e 's/%password/#{db_password}/g' #{shared_path}/settings.php"
    end
  end
  
  namespace :git do

    desc "Place release tag into Git and push it to origin server."
    task :push_deploy_tag do
      user = `git config --get user.name`
      email = `git config --get user.email`
      tag = "release_#{release_name}"
      run("cd #{repository_cache_path} && git tag #{tag} #{revision} -m 'Deployed by #{user} <#{email}>'")
      run("cd #{repository_cache_path} && git push origin tag #{tag}")
    end

    desc "Place release tag into Git and push it to server."
    task :cleanup_deploy_tag do
      count = fetch(:keep_releases, 5).to_i
      if count >= releases.length
        logger.important "no old release tags to clean up"
      else
        logger.info "keeping #{count} of #{releases.length} release tags"

        tags = (releases - releases.last(count)).map { |release| "release_#{release}" }

        tags.each do |tag|
          run("cd #{repository_cache_path} && git tag -d #{tag}")
          run("cd #{repository_cache_path} && git push origin :refs/tags/#{tag}")
        end
      end
    end
  end
  
  namespace :drush do

    desc "Backup the database"
    task :backupdb, :on_error => :continue do
      t = Time.now.utc.strftime("%Y-%m-%dT%H-%M-%S")
      run "drush -r #{release_path} sql-dump --gzip --result-file=#{shared_path}/backups/#{t}.sql"
    end

    desc "Run Drupal database migrations if required"
    task :updatedb, :on_error => :continue do
      run "drush -r #{release_path} updatedb -y"
    end

    desc "Clear the drupal cache"
    task :cache_clear, :on_error => :continue do
      run "drush -r #{release_path}  cc all"
    end

    desc "Create the database"
    task :createdb, :on_error => :continue do
      run "mysqladmin create #{db_name}"
      run "mysql -e \"grant all on #{db_name}.* to '#{db_username}'@'localhost' identified by '#{db_password}'\""
    end

  end
  
end
