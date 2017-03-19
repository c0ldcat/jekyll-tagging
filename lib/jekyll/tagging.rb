require 'nuggets/range/quantile'
require 'nuggets/i18n'
require 'erb'

module Jekyll

  module Helpers

    # call-seq:
    #   jekyll_tagging_slug(str) => new_str
    #
    # Substitutes any diacritics in _str_ with their ASCII equivalents,
    # whitespaces with dashes and converts _str_ to downcase.
    def jekyll_tagging_slug(str)
      str.to_s.replace_diacritics.downcase.gsub(/\s/, '-')
    end

  end

  class Tagger < Generator

    include Helpers

    safe true

    attr_accessor :site

    @types = [:page, :feed]

    class << self; attr_accessor :types, :site; end

    def generate(site)
      self.class.site = self.site = site

      generate_tag_pages
      add_tag_cloud

      if TagsPage.pagination_enabled?(site)
        if template = self.class.template_page(site)
          paginate(site, template)
        end
      end
    end

    private

    # Generates a page per tag and adds them to all the pages of +site+.
    # A <tt>tag_page_layout</tt> have to be defined in your <tt>_config.yml</tt>
    # to use this.
    def generate_tag_pages
      active_tags.each { |tag, posts| new_tag(tag, posts) }
    end

    def new_tag(tag, posts)
      self.class.types.each { |type|
        if layout = site.config["tag_#{type}_layout"]
          data = { 'layout' => layout, 'posts' => posts.sort.reverse!, 'tag' => tag, 'title' => tag }
          data.merge!(site.config["tag_#{type}_data"] || {})

          name = yield data if block_given?
          name ||= tag
          name = jekyll_tagging_slug(name)

          tag_dir = site.config["tag_#{type}_dir"]
          tag_dir = File.join(tag_dir, (pretty? ? name : ''))

          page_name = "#{pretty? ? 'index' : name}#{site.layouts[data['layout']].ext}"

          site.pages << TagPage.new(
            site, site.source, tag_dir, page_name, data
          )
        end
      }
    end

    def add_tag_cloud(num = 5, name = 'tag_data')
      s, t = site, { name => calculate_tag_cloud(num) }
      s.respond_to?(:add_payload) ? s.add_payload(t) : s.config.update(t)
    end

    # Calculates the css class of every tag for a tag cloud. The possible
    # classes are: set-1..set-5.
    #
    # [[<TAG>, <CLASS>], ...]
    def calculate_tag_cloud(num = 5)
      range = 0

      tags = active_tags.map { |tag, posts|
        [tag.to_s, range < (size = posts.size) ? range = size : size]
      }


      range = 1..range

      tags.sort!.map! { |tag, size| [tag, range.quantile(size, num)] }
    end

    def active_tags
      return site.tags unless site.config["ignored_tags"]
      site.tags.reject { |t| site.config["ignored_tags"].include? t[0] }
    end

    def pretty?
      @pretty ||= (site.permalink_style == :pretty || site.config['tag_permalink_style'] == 'pretty')
    end

    # Paginates the blog's posts. Renders the index.html file into paginated
    # directories, e.g.: page2/index.html, page3/index.html, etc and adds more
    # site-wide data.
    #
    # site - The Site.
    # page - The index.html Page that requires pagination.
    #
    # {"paginator" => { "page" => <Number>,
    #                   "per_page" => <Number>,
    #                   "tags" => [<Tags>],
    #                   "total_tags" => <Number>,
    #                   "total_pages" => <Number>,
    #                   "previous_page" => <Number>,
    #                   "next_page" => <Number> }}
    def paginate(site, page)
      pages = TagsPage.calculate_pages(active_tags, site.config['tags_paginate'].to_i)
      (1..pages).each do |num_page|
        pager = TagsPage.new(site, num_page, active_tags, pages)
        if num_page > 1
          newpage = Page.new(site, site.source, page.dir, page.name)
          newpage.pager = pager
          newpage.dir = TagsPage.paginate_path(site, num_page)
          site.pages << newpage
        else
          page.pager = pager
        end
      end
    end

    # Static: Fetch the URL of the template page. Used to determine the
    #         path to the first pager in the series.
    #
    # site - the Jekyll::Site object
    #
    # Returns the url of the template page
    def self.first_page_url(site)
      if page = Tagger.template_page(site)
        page.url
      else
        nil
      end
    end

    # Public: Find the Jekyll::Page which will act as the pager template
    #
    # site - the Jekyll::Site object
    #
    # Returns the Jekyll::Page which will act as the pager template
    def self.template_page(site)
      site.pages.select do |page|
        TagsPage.pagination_candidate?(site.config, page)
      end.sort do |one, two|
        two.path.size <=> one.path.size
      end.first
    end

  end

  class TagPage < Page

    def initialize(site, base, dir, name, data = {})
      self.content = data.delete('content') || ''
      self.data    = data

      super(site, base, dir[-1, 1] == '/' ? dir : '/' + dir, name)
    end

    def read_yaml(*)
      # Do nothing
    end

  end

  class TagsPage
    attr_reader :page, :per_page, :tags, :total_tags, :total_pages,
      :previous_page, :previous_page_path, :next_page, :next_page_path

    # Calculate the number of pages.
    #
    # all_tags - The Array of all Tags.
    # per_page  - The Integer of entries per page.
    #
    # Returns the Integer number of pages.
    def self.calculate_pages(all_tags, per_page)
      (all_tags.size.to_f / per_page.to_i).ceil
    end

    # Determine if pagination is enabled the site.
    #
    # site - the Jekyll::Site object
    #
    # Returns true if pagination is enabled, false otherwise.
    def self.pagination_enabled?(site)
     !site.config['tags_paginate'].nil? &&
       site.pages.size > 0
    end

    # Static: Determine if a page is a possible candidate to be a template page.
    #         Page's name must be `index.html` and exist in any of the directories
    #         between the site source and `paginate_path`.
    #
    # config - the site configuration hash
    # page   - the Jekyll::Page about which we're inquiring
    #
    # Returns true if the
    def self.pagination_candidate?(config, page)
      page_dir = File.dirname(File.expand_path(remove_leading_slash(page.path), config['source']))
      paginate_path = remove_leading_slash(config['tags_paginate_path'])
      paginate_path = File.expand_path(paginate_path, config['source'])
      page.name == 'index.html' &&
        in_hierarchy(config['source'], page_dir, File.dirname(paginate_path))
    end

    # Determine if the subdirectories of the two paths are the same relative to source
    #
    # source        - the site source
    # page_dir      - the directory of the Jekyll::Page
    # paginate_path - the absolute paginate path (from root of FS)
    #
    # Returns whether the subdirectories are the same relative to source
    def self.in_hierarchy(source, page_dir, paginate_path)
      return false if paginate_path == File.dirname(paginate_path)
      return false if paginate_path == Pathname.new(source).parent
      page_dir == paginate_path ||
        in_hierarchy(source, page_dir, File.dirname(paginate_path))
    end

    # Static: Return the pagination path of the page
    #
    # site     - the Jekyll::Site object
    # num_page - the pagination page number
    #
    # Returns the pagination path as a string
    def self.paginate_path(site, num_page)
      return nil if num_page.nil?
      return Tagger.first_page_url(site) if num_page <= 1
      format = site.config['tags_paginate_path']
      if format.include?(":num")
        format = format.sub(':num', num_page.to_s)
      else
        raise ArgumentError.new("Invalid pagination path: '#{format}'. It must include ':num'.")
      end
      ensure_leading_slash(format)
    end

    # Static: Return a String version of the input which has a leading slash.
    #         If the input already has a forward slash in position zero, it will be
    #         returned unchanged.
    #
    # path - a String path
    #
    # Returns the path with a leading slash
    def self.ensure_leading_slash(path)
      path[0..0] == "/" ? path : "/#{path}"
    end

    # Static: Return a String version of the input without a leading slash.
    #
    # path - a String path
    #
    # Returns the input without the leading slash
    def self.remove_leading_slash(path)
      ensure_leading_slash(path)[1..-1]
    end

    # Initialize a new Pager.
    #
    # site     - the Jekyll::Site object
    # page      - The Integer page number.
    # all_tags - The Array of all the site's Tags.
    # num_pages - The Integer number of pages or nil if you'd like the number
    #             of pages calculated.
    def initialize(site, page, all_tags, num_pages = nil)
      @page = page
      @per_page = site.config['tags_paginate'].to_i
      @total_pages = num_pages || TagsPage.calculate_pages(all_tags, @per_page)

      if @page > @total_pages
        raise RuntimeError, "page number can't be greater than total pages: #{@page} > #{@total_pages}"
      end

      init = (@page - 1) * @per_page
      offset = (init + @per_page - 1) >= all_tags.size ? all_tags.size : (init + @per_page - 1)

      @total_tags = all_tags.size
      @tags = all_tags.to_a[init..offset].to_h
      @previous_page = @page != 1 ? @page - 1 : nil
      @previous_page_path = TagsPage.paginate_path(site, @previous_page)
      @next_page = @page != @total_pages ? @page + 1 : nil
      @next_page_path = TagsPage.paginate_path(site, @next_page)
    end

    # Convert this Pager's data to a Hash suitable for use by Liquid.
    #
    # Returns the Hash representation of this Pager.
    def to_liquid
      {
        'page' => page,
        'per_page' => per_page,
        'tags' => tags,
        'total_tags' => total_tags,
        'total_pages' => total_pages,
        'previous_page' => previous_page,
        'previous_page_path' => previous_page_path,
        'next_page' => next_page,
        'next_page_path' => next_page_path
      }
    end

  end

  module TaggingFilters

    include Helpers

    def tag_cloud(site)
      active_tag_data.map { |tag, set|
        tag_link(tag, tag_url(tag), :class => "set-#{set}")
      }.join(' ')
    end

    def tag_link(tag, url = tag_url(tag), html_opts = nil)
      html_opts &&= ' ' << html_opts.map { |k, v| %Q{#{k}="#{v}"} }.join(' ')
      %Q{<a href="#{url}"#{html_opts}>#{tag}</a>}
    end

    def tag_url(tag, type = :page, site = Tagger.site)
      url = File.join('', site.config["baseurl"].to_s, site.config["tag_#{type}_dir"], ERB::Util.u(jekyll_tagging_slug(tag)))
      site.permalink_style == :pretty || site.config['tag_permalink_style'] == 'pretty' ? url << '/' : url << '.html'
    end

    def tags(obj)
      tags = obj['tags'].dup
      tags.map! { |t| t.first } if tags.first.is_a?(Array)
      tags.map! { |t| tag_link(t, tag_url(t), :rel => 'tag') if t.is_a?(String) }.compact!
      tags.join(', ')
    end

    def keywords(obj)
      return '' if not obj['tags']
      tags = obj['tags'].dup
      tags.join(',')
    end

    def active_tag_data(site = Tagger.site)
      return site.config['tag_data'] unless site.config["ignored_tags"]
      site.config["tag_data"].reject { |tag, set| site.config["ignored_tags"].include? tag }
    end
  end

  module TagSortFilters
    include Helpers
    
    def tag_sort(site)
      site.tags.sort { |a, b| a[1].length <=> b[1].length }
    end
  end

end

Liquid::Template.register_filter(Jekyll::TaggingFilters)
Liquid::Template.register_filter(Jekyll::TagSortFilters)
