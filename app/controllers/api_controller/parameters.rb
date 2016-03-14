class ApiController
  module Parameters
    def paginate_params?
      params['offset'] || params['limit']
    end

    def expand_paginate_params
      offset = params['offset']   # 0 based
      limit  = params['limit']    # i.e. page size
      [offset, limit]
    end

    def json_body
      @req[:body] ||= begin
        body = request.body.read if request.body
        body.blank? ? {} : JSON.parse(body)
      end
    end

    def hash_fetch(hash, element, default = {})
      hash[element] || default
    end

    #
    # Returns an MiqExpression based on the filter attributes specified.
    #
    def filter_param(klass)
      return nil if params['filter'].blank?

      operators = {
        "!=" => {:default => "!=", :regex => "REGULAR EXPRESSION DOES NOT MATCH", :null => "IS NOT NULL"},
        "<=" => {:default => "<="},
        ">=" => {:default => ">="},
        "<"  => {:default => "<"},
        ">"  => {:default => ">"},
        "="  => {:default => "=", :regex => "REGULAR EXPRESSION MATCHES", :null => "IS NULL"}
      }

      and_expressions = []
      or_expressions = []

      params['filter'].select(&:present?).each do |filter|
        parsed_filter = parse_filter(filter, operators)
        parts = parsed_filter[:attr].split(".")
        field = if parts.one?
                  unless klass.attribute_method?(parsed_filter[:attr]) || klass.virtual_attribute?(parsed_filter[:attr])
                    raise BadRequestError, "attribute #{parsed_filter[:attr]} does not exist"
                  end
                  "#{klass.name}-#{parsed_filter[:attr]}"
                else
                  "#{klass.name}.#{parts[0..-2].join(".")}-#{parts.last}"
                end
        target = parsed_filter[:logical_or] ? or_expressions : and_expressions
        target << {parsed_filter[:operator] => {"field" => field, "value" => parsed_filter[:value]}}
      end

      and_part = and_expressions.one? ? and_expressions.first : {"AND" => and_expressions}
      composite_expression = or_expressions.empty? ? and_part : {"OR" => [and_part, *or_expressions]}
      MiqExpression.new(composite_expression)
    end

    def parse_filter(filter, operators)
      logical_or = filter.gsub!(/^or /i, '').present?
      operator, methods = operators.find { |op, _methods| filter.partition(op).second == op }

      raise BadRequestError,
            "Unknown operator specified in filter #{filter}" if operator.blank?

      filter_attr, _, filter_value = filter.partition(operator)
      filter_value.strip!
      str_method = filter_value =~ /%|\*/ && methods[:regex] || methods[:default]

      filter_value, method =
        case filter_value
        when /^'.*'$/
          [filter_value.gsub(/^'|'$/, ''), str_method]
        when /^".*"$/
          [filter_value.gsub(/^"|"$/, ''), str_method]
        when /^(NULL|nil)$/i
          [nil, methods[:null] || methods[:default]]
        else
          [filter_value, methods[:default]]
        end

      if filter_value =~ /%|\*/
        filter_value = "/\\A#{Regexp.escape(filter_value)}\\z/"
        filter_value.gsub!(/%|\\\*/, ".*")
      end

      {:logical_or => logical_or, :operator => method, :attr => filter_attr.strip, :value => filter_value}
    end

    def by_tag_param
      params['by_tag']
    end

    def expand_param
      params['expand'] && params['expand'].split(",")
    end

    def expand?(what)
      expand_param ? expand_param.include?(what.to_s) : false
    end

    def attribute_selection
      if params['attributes'] || @req[:additional_attributes]
        params['attributes'].to_s.split(",") | Array(@req[:additional_attributes]) | ID_ATTRS
      else
        "all"
      end
    end

    def render_attr(attr)
      as = attribute_selection
      as == "all" || as.include?(attr)
    end

    #
    # Returns the ActiveRecord's option for :order
    #
    # i.e. ['attr1 [asc|desc]', 'attr2 [asc|desc]', ...]
    #
    def sort_params(klass)
      return [] if params['sort_by'].blank?

      orders = String(params['sort_order']).split(",")
      options = String(params['sort_options']).split(",")
      params['sort_by'].split(",").zip(orders).collect do |attr, order|
        if klass.attribute_method?(attr) || klass.method_defined?(attr) || attr == klass.primary_key
          sort_directive(attr, order, options)
        else
          raise BadRequestError, "#{attr} is not a valid attribute for #{klass.name}"
        end
      end.compact
    end

    def sort_directive(attr, order, options)
      sort_item = attr
      sort_item = "LOWER(#{sort_item})" if options.map(&:downcase).include?("ignore_case")
      sort_item << " ASC"  if order && order.downcase.start_with?("asc")
      sort_item << " DESC" if order && order.downcase.start_with?("desc")
      sort_item
    end
  end
end
