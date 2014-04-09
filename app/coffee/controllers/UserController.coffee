User = require('../models/User').User
sanitize = require('sanitizer')
fs = require('fs')
_ = require('underscore')
logger = require('logger-sharelatex')
Security = require('../managers/SecurityManager')
Settings = require('settings-sharelatex')
newsLetterManager = require('../Features/Newsletter/NewsletterManager')
dropboxHandler = require('../Features/Dropbox/DropboxHandler')
userRegistrationHandler = require('../Features/User/UserRegistrationHandler')
metrics = require('../infrastructure/Metrics')
ReferalAllocator = require('../Features/Referal/ReferalAllocator')
AuthenticationManager = require("../Features/Authentication/AuthenticationManager")
AuthenticationController = require("../Features/Authentication/AuthenticationController")
SubscriptionLocator = require("../Features/Subscription/SubscriptionLocator")
UserDeleter = require("../Features/User/UserDeleter")
EmailHandler = require("../Features/Email/EmailHandler")
Url = require("url")
uuid = require("node-uuid")

module.exports =

	apiRegister : (req, res, next = (error) ->)->
		logger.log email: req.body.email, "attempted register"
		redir = Url.parse(req.body.redir or "/project").path
		userRegistrationHandler.validateRegisterRequest req, (err, data)->
			if err?
				logger.log validation_error: err, "user validation error"
				metrics.inc "user.register.validation-error"
				res.send message:
					 text:err
					 type:'error'
			else
				User.findOne {email:data.email}, (err, foundUser)->
					if foundUser? && foundUser.holdingAccount == false
						AuthenticationController.login req, res
						logger.log email: data.email, "email already registered"
						metrics.inc "user.register.already-registered"
						return AuthenticationController.login req, res
					else if foundUser? && foundUser.holdingAccount == true #someone put them in as a collaberator
						user = foundUser
						user.holdingAccount = false
					else
						user = new User email: data.email
					d = new Date()
					user.first_name = data.first_name
					user.last_name = data.last_name
					user.signUpDate = new Date()
					metrics.inc "user.register.success"
					user.save (err)->
						req.session.user = user
						req.session.justRegistered = true
						logger.log user: user, "registered"
						AuthenticationManager.setUserPassword user._id, data.password, (error) ->
							return next(error) if error?
							res.send
								redir:redir
								id:user._id.toString()
								first_name: user.first_name
								last_name: user.last_name
								email: user.email
								created: Date.now()
					#things that can be fired and forgot.
					newsLetterManager.subscribe user
					ReferalAllocator.allocate req.session.referal_id, user._id, req.session.referal_source, req.session.referal_medium
					emailOpts =
						first_name:user.first_name
						to: user.email
					EmailHandler.sendEmail "welcome", emailOpts



	doRequestPasswordReset : (req, res, next = (error) ->)->
		email = sanitize.escape(req.body.email)
		email = sanitize.escape(email).trim()
		email = email.toLowerCase()
		logger.log email: email, "password reset requested"
		User.findOne {'email':email}, (err, user)->
			if(user?)
				randomPassword = uuid.v4()
				AuthenticationManager.setUserPassword user._id, randomPassword, (error) ->
					emailOpts =
						newPassword: randomPassword
						to: user.email
					EmailHandler.sendEmail "passwordReset", emailOpts, (err)->
						if err?
							logger.err err:err, emailOpts:emailOpts, "problem sending password reset email"
							return res.send 500
						metrics.inc "user.password-reset"
						res.send message:
							 text:'An email with your new password has been sent to you'
							 type:'success'
			else
				res.send message:
					 text:'This email address has not been registered with us'
					 type:'failure'
				logger.info email: email, "no user found with email"
				
	logout : (req, res)->
		metrics.inc "user.logout"
		if req.session? && req.session.user?
			logger.log user: req.session.user, "logging out"
		req.session.destroy (err)->
			if err
				logger.err err: err, 'error destorying session'
			res.redirect '/login'

	settings : (req, res)->
		logger.log user: req.session.user, "loading settings page"
		User.findById req.session.user._id, (err, user)->
			dropboxHandler.getUserRegistrationStatus user._id, (err, status)->
				userIsRegisteredWithDropbox = !err? and status.registered
				res.render 'user/settings',
					title:'Your settings',
					userCanSeeDropbox: user.featureSwitches.dropbox
					userHasDropboxFeature: user.features.dropbox
					userIsRegisteredWithDropbox: userIsRegisteredWithDropbox
					user: user,
					themes: THEME_LIST,
					editors: ['default','vim','emacs'],
					fontSizes: ['10','11','12','13','14','16','20','24']
					languages: Settings.languages,
					accountSettingsTabActive: true

	unsubscribe: (req, res)->
		User.findById req.session.user._id, (err, user)->
			newsLetterManager.unsubscribe user, ->
				res.send()

	apiUpdate : (req, res)->
		logger.log user: req.session.user, "updating account settings"
		metrics.inc "user.settings-update"
		User.findById req.session.user._id, (err, user)->
			if(user)
				user.first_name   = sanitize.escape(req.body.first_name).trim()
				user.last_name    = sanitize.escape(req.body.last_name).trim()
				user.ace.mode     = sanitize.escape(req.body.mode).trim()
				user.ace.theme    = sanitize.escape(req.body.theme).trim()
				user.ace.fontSize = sanitize.escape(req.body.fontSize).trim()
				user.ace.autoComplete = req.body.autoComplete == "true"
				user.ace.spellCheckLanguage = req.body.spellCheckLanguage
				user.ace.pdfViewer = req.body.pdfViewer
				user.save()
				res.send {}

	changePassword : (req, res, next = (error) ->)->
		metrics.inc "user.password-change"
		oldPass = req.body.currentPassword
		AuthenticationManager.authenticate _id: req.session.user._id, oldPass, (err, user)->
			return next(err) if err?
			if(user)
				logger.log user: req.session.user, "changing password"
				newPassword1 = req.body.newPassword1
				newPassword2 = req.body.newPassword2
				if newPassword1 != newPassword2
					logger.log user: user, "passwords do not match"
					res.send
						message:
						  type:'error'
						  text:'Your passwords do not match'
				else
					logger.log user: user, "password changed"
					AuthenticationManager.setUserPassword user._id, newPassword1, (error) ->
						return next(error) if error?
						res.send
							message:
							  type:'success'
							  text:'Your password has been changed'
			else
				logger.log user: user, "current password wrong"
				res.send
					message:
					  type:'error'
					  text:'Your old password is wrong'



	deleteUser: (req, res)->
		user_id = req.session.user._id
		UserDeleter.deleteUser user_id, (err)->
			if !err?
				req.session.destroy()
			res.send(200)


THEME_LIST = []
do generateThemeList = () ->
	files = fs.readdirSync __dirname + '/../../../public/js/ace/theme'
	for file in files
		if file.slice(-2) == "js"
			cleanName = file.slice(0,-3)
			THEME_LIST.push name: cleanName
