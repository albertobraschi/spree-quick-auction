class QuickAuctionExtension < Spree::Extension
  version "1.0"
  description "Quick Auction extension for spree"
  url "http://github.com/pronix/spree-quick-auction"

  def activate
    
    LineItem.class_eval do
      before_update :fix_quantity
      
      # Some hack. Becouse I don't know the reason why :quantity set to +1
      # if :quantity is not 0
      # TODO: try to kosher way to don't do this
      def fix_quantity
        self.quantity = 1
      end
      
    end
        
    Product.class_eval do
      def change_variants
        if !self.count_on_hand.nil? && self.count_on_hand != 0
          counts = self.count_on_hand
          counts.times.each do |price|
            variant = self.variants.create(:sku => self.sku + '-' + price.to_s,
                                           :price => self.price + (price.to_i + 1 - 1) * self.step,
                                           :count_on_hand => 1)
            self.option_types.each do |option_type|
              variant.option_values << option_type.option_values.last
            end
          end
        end
      end
      
      named_scope :availables, :conditions => ['available_on <= ? AND available_off >= ?',
                                               Time.now.utc.to_s(:db), Time.now.utc.to_s(:db)], :order => 'created_at DESC'
      
      def available?
        return true if self.available_on <= Time.now && self.available_off >= Time.now
      end
      
      class << self
        def available_last
          self.availables.map {|x| x if x.has_variants?}.compact.try(:first)
        end
      end
      
    end
    
    # ApplicationController.class_eval do
    #   helper_method :session_variant
      
    #   def session_variant
    #     begin
    #       Variant.find(session[:products][:variant_id])
    #     rescue 
    #       nil
    #     end
    #   end
    # end
    
    CheckoutsController.class_eval do
      edit.before { @order.update_totals! }
    end
    
    ProductsController.class_eval do
      before_filter :redirect_to_main, :only => :index
      
      # Basically redirect to / if user respone to /products
      # I think it's more nice, that dirty routes, but it still very stupid
      def redirect_to_main
        redirect_to root_path
      end
      
    end
    
    OrdersController.class_eval do
      before_filter :fix_type_values, :only => [:create]
      before_filter :remember_variant_options, :only => [:create]
      
      # When user click to Buy Now we redirect he to checkout edit page
      create do
        flash nil
	    # success.wants.html {redirect_to edit_order_url(@order)}
        success.wants.html {redirect_to edit_order_checkout_path(@order)}
        failure.wants.html {redirect_to edit_order_checkout_path(@order)}
      end
      
      # This staff save variants choices in session and don't change
      # a variant
      def remember_variant_options
        # Simple precaution
        if params[:products].blank?
          return
        else
          # All product types are necessary
          Variant.find(params[:products][:variant_id].to_i).product.option_types.each do |ot|
            unless params.include?(ot.name.to_sym)
              flash[:notice] = "Sorry, but u must choice product options"
              redirect_to :back and return   
            end
          end
        end
        # Save only one choice in session.
        session[:products] = { :variant_id => params[:products][:variant_id].to_i }
        Variant.find(params[:products][:variant_id].to_i).product.option_types.each do |ot|
          session[:products].merge!({ ot.name.to_sym => params[ot.name.to_sym].to_i })
        end
      end
            
      # Fix quanity, I don't know why, but its step to 2
      def fix_type_values
        params.merge!({:quantity => "1"})
      end
      
    end
    
    Admin::ProductsController.class_eval do
      before_filter :fix_on_hand, :only => :update
      after_filter :add_variants, :only => :update
      
      # When we try to update product edit page, rails send on_hand in params
      # It's must me deleted when products already has a variants
      def fix_on_hand
        params[:product].delete(:on_hand) unless Product.find_by_permalink(params[:id]).variants.blank?
      end
      
      # Add variont to Product. See method @product.change_variants
      def add_variants
        @product.change_variants if @product.variants.blank?
      end
      
    end
    
    CheckoutsController.class_eval do
      helper QuickAuctionsHelper
      prepend_before_filter :check_variant
      before_filter :change_product_options, :only => :update
      
      private
      
      def change_product_options
        return unless params[:step] == "payment"
        begin
          variant = Variant.find(session[:products][:variant_id])
          variant.option_values.clear
          variant.product.option_types.each do |ot|
            variant.option_values << OptionValue.find(session[:products][ot.name.to_sym])
          end
          # variant.product.option_types.map {|option| option.name}.each do |option_name|
          #   session[:products].each do |product|
          #     variant.option_values << OptionValue.find(product[option_name.to_sym])
              
          #   end
          # end
          # session[:products].each do |variant|
          #   variant = Variant.find(variant[:variant_id].to_i)
          #   variant.option_values.clear
          #   variant.product.option_types.map {|option| option.name}.each do |option_name|
          #     session[:products].each do |product|
          #       variant.option_values << OptionValue.find(product[option_name.to_sym])
          #     end
          #   end
          # end
        end
      end
      
      def check_variant
        variant = Variant.find(session[:products][:variant_id])
        unless variant.in_stock? && variant.available?
          flash[:notice] = 'Sorry but the product has been sold or not available'
          redirect_to root_path and return
        end
      end
      
    end
    
    Spree::BaseHelper.class_eval do
      # Return a string with variant options and values
      def variant_options_session(variant)
        return '' unless session.include?(:products)
        to_out = []
        if session[:products][:variant_id] == variant.id
          variant.product.option_types.each do |ot|
            to_out << "#{ot.presentation}: #{OptionValue.find(session[:products][ot.name.to_sym]).presentation}"
          end
        end
        to_out.join(', ')
      end
      
      # Show two times available_on and availbale_off in right format
      def show_available_times(product)
        return_time = { }
        if product.available_on.nil?
          return_time.merge!({ :available_on => Time.now.to_formatted_s(:date_time24)})
        else
          return_time.merge!({ :available_on => product.available_on.to_formatted_s(:date_time24)})
        end
        if product.available_off.nil?
          return_time.merge!({ :available_off => (Time.now + 4.hour).to_formatted_s(:date_time24)})
        else
          return_time.merge!({ :available_off => product.available_off.to_formatted_s(:date_time24)})
        end
        return_time
      end
      
    end

  end
    
end
