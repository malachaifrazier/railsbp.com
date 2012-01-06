require 'exceptions/authorization_exception'

class Repository < ActiveRecord::Base
  has_many :user_repositories
  has_many :users, through: :user_repositories, uniq: true
  has_many :builds, dependent: :destroy

  validates :github_name, presence: true, uniqueness: true
  validates :github_id, uniqueness: true

  before_create :reset_authentication_token, :sync_github
  after_create :copy_config_file

  scope :visible, where(:visible => true)

  def clone_url
    private? ? ssh_url : git_url
  end

  def default_config_file_path
    Rails.root.join("config/rails_best_practices.yml").to_s
  end

  def config_path
    Rails.root.join("builds", github_name).to_s
  end

  def config_file_path
    config_path + "/rails_best_practices.yml"
  end

  def generate_build(commit)
    build = self.builds.build(last_commit_id: commit["id"], last_commit_message: commit["message"])
    if build.save
      build.analyze
    end
  end

  def generate_proxy_build(commit, errors)
    build = self.builds.build(last_commit_id: commit["id"], last_commit_message: commit["message"], warnings: errors)
    if build.save
      build.proxy_analyze
    end
  end

  def sync_collaborators
    Delayed::Job.enqueue(DelayedJob::SyncCollaborators.new(self.id, User.current.github_token))
  end

  def delete_collaborator(user_id)
    user_repositories.where(user_id: user_id).destroy
  end

  def add_collaborator(login)
    client = Octokit::Client.new(oauth_token: User.current.github_token)
    github_user = client.user(login)

    unless user = User.where(github_uid: github_user.id).first
      user = User.new(email: "#{github_user.login}@fakemail.com", password: Devise.friendly_token[0, 20])
      user.github_uid = github_user.id
      user.name = github_user.name
      user.nickname = github_user.login
      user.save
    end
    add_collaborator_if_necessary(user)
  end

  def add_collaborator_if_necessary(user)
    unless collaborator_ids.include?(user.id)
      self.users << user
    end
  end

  def collaborator_ids
    user_repositories.map(&:user_id)
  end

  protected
    def reset_authentication_token
      self.authentication_token = Devise.friendly_token
    end

    def sync_github
      client = Octokit::Client.new(oauth_token: User.current.github_token)
      repo = client.repository(github_name)
      self.html_url = repo.html_url
      self.git_url = repo.git_url
      self.ssh_url = repo.ssh_url
      self.name = repo.name
      self.description = repo.description
      self.private = repo.private
      self.fork = repo.fork
      self.pushed_at = repo.pushed_at
      self.github_id = repo.id
      self.visible = !repo.private
    end

    def copy_config_file
      FileUtils.mkdir_p(config_path) unless File.exist?(config_path)
      FileUtils.cp(default_config_file_path, config_file_path)
    end
end
