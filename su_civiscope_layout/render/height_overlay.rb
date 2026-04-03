# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    class CiviscopeHeightCheckOverlay < Sketchup::Overlay
      attr_accessor :sites_data
      
      def initialize
        super("civiscope_height_check", "地块限高检测")
        @sites_data = {} # { id_str => { local_pts: [], violated: false } }
      end
      
      def draw(view)
        model = Sketchup.active_model
        @sites_data.each do |id_str, data|
          site = model.find_entity_by_persistent_id(id_str.to_i)
          site ||= model.entities.to_a.find { |e| CiviscopeLayout::Core.get_short_id(e) == id_str }
          next unless site
          
          limit_m = site.get_attribute("dynamic_attributes", "height_limit").to_f
          next if limit_m <= 0
          
          tr_world = CiviscopeLayout::Core.get_full_world_transform(site)
          local_pts = data[:local_pts]
          pts = local_pts.map { |p| p.transform(tr_world) }
          
          limit_inch = limit_m / 0.0254
          is_violated = data[:violated]
          
          color = is_violated ? Sketchup::Color.new(255, 0, 0, 70) : Sketchup::Color.new(150, 150, 150, 70)
          edge_color = is_violated ? Sketchup::Color.new(255, 0, 0, 150) : Sketchup::Color.new(100, 100, 100, 150)
          
          top_pts = pts.map { |p| p.offset([0, 0, limit_inch]) }
          
          pts.each_with_index do |p, i|
            p2 = pts[(i + 1) % pts.length]
            t1 = top_pts[i]
            t2 = top_pts[(i + 1) % top_pts.length]
            view.drawing_color = color
            view.draw(GL_QUADS, p, p2, t2, t1)
            view.drawing_color = edge_color
            view.line_width = 1
            view.draw(GL_LINE_STRIP, p, p2, t2, t1, p)
          end
          view.drawing_color = color
          view.draw(GL_POLYGON, top_pts)
          view.drawing_color = edge_color
          view.draw(GL_LINE_LOOP, top_pts)
        end
      end
    end

    def self.ensure_height_check_overlay(model)
      @overlay ||= CiviscopeHeightCheckOverlay.new
      begin
        model.overlays.add(@overlay) unless model.overlays.to_a.include?(@overlay)
      rescue => e; end
    end

    def self.do_toggle_height_check(id_str)
      model = Sketchup.active_model
      site = model.find_entity_by_persistent_id(id_str.to_i)
      site ||= model.entities.to_a.find { |e| self.get_short_id(e) == id_str }
      return unless site
      
      self.ensure_height_check_overlay(model)
      
      if @overlay.sites_data.key?(id_str)
        @overlay.sites_data.delete(id_str)
      else
        self.add_site_to_height_check(site)
      end
      UI.start_timer(0, false) { Sketchup.active_model.active_view.refresh }
      self.refresh_stats_ui(model.selection)
    end

    def self.do_set_all_height_checks(status_bool)
      model = Sketchup.active_model
      self.ensure_height_check_overlay(model)
      
      if status_bool
        # Scan all definitions and their instances for sites
        model.definitions.each do |d|
          next if d.image?
          d.instances.each do |inst| 
            if inst.get_attribute("dynamic_attributes", "site_func")
              self.add_site_to_height_check(inst)
            end
          end
        end
      else
        @overlay.sites_data.clear
      end
      
      model.active_view.invalidate
      UI.start_timer(0, false) { model.active_view.refresh }
      self.refresh_stats_ui(model.selection)
    end

    def self.add_site_to_height_check(site)
      id_str = self.get_short_id(site)
      return if @overlay.sites_data.key?(id_str)
      
      limit_m = site.get_attribute("dynamic_attributes", "height_limit").to_f
      return if limit_m <= 0
      
      definition = site.is_a?(Sketchup::Group) ? site.definition : (site.respond_to?(:definition) ? site.definition : nil)
      return unless definition
      
      # Use first horizontal face or fallback to bounds
      face = definition.entities.grep(Sketchup::Face).find { |f| f.normal.z.abs > 0.99 }
      if face
        local_pts = face.outer_loop.vertices.map { |v| v.position }
      else
        b = definition.bounds
        local_pts = [b.corner(0), b.corner(1), b.corner(3), b.corner(2)]
      end
      
      @overlay.sites_data[id_str] = { local_pts: local_pts, violated: false }
      self.update_overlay_state(id_str)
    end

    def self.update_overlay_state(id_str)
      return unless @overlay && @overlay.sites_data[id_str]
      data = @overlay.sites_data[id_str]
      model = Sketchup.active_model
      
      # Use persistent ID or custom traversal if needed
      site = model.find_entity_by_persistent_id(id_str.to_i)
      unless site
        # Search all definitions for instances matching the short ID (fallback)
        model.definitions.each do |d|
          site = d.instances.find { |i| self.get_short_id(i) == id_str }
          break if site
        end
      end
      return unless site && site.valid?
      
      tr_site = self.get_full_world_transform(site)
      limit_m = site.get_attribute("dynamic_attributes", "height_limit").to_f
      limit_inch = limit_m / 0.0254
      
      site_box = site.definition.bounds
      site_min_z = (tr_site * site_box.min).z
      
      # find_buildings_on_site now returns actual entities
      bldg_ents = self.find_buildings_on_site(site)
      is_violated = false
      
      bldg_ents.each do |b_ent|
        next unless b_ent.valid?
        tr_b = self.get_full_world_transform(b_ent)
        local_box = b_ent.definition.bounds
        
        # Check world max Z against site min Z + limit
        w_max_z = -100000000
        (0..7).each do |i| 
          z = (tr_b * local_box.corner(i)).z
          w_max_z = z if z > w_max_z 
        end
        
        if w_max_z > site_min_z + (limit_inch - 0.001)
          is_violated = true
          break
        end
      end
      data[:violated] = is_violated
    end

  end
end
